import XCTest

/// Drives the real app UI. Each test injects its GateConfig through the
/// UserDefaults argument domain (`-hearth.config.json <hex>`), which overrides
/// whatever an earlier run saved, so no test hooks are needed in the app.
final class HearthUITests: XCTestCase {

    /// SHA-256 of "1234".
    private let pin1234Hash = "03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ config: [String: Any]) -> XCUIApplication {
        var cfg: [String: Any] = [
            "probeIntervalSeconds": 15,
            "allowlist": [String](),
            "denylist": [String](),
            "enforceSafeSearch": true,
            "homeURL": "about:blank",
        ]
        cfg.merge(config) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: cfg)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let app = XCUIApplication()
        app.launchArguments = ["-hearth.config.json", "<\(hex)>"]
        app.launch()
        return app
    }

    private var blockedText: String { "That site isn't on the allowed list." }

    private func addressBar(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["Search or enter a site"]
    }

    private func go(_ app: XCUIApplication, to text: String) {
        let bar = addressBar(app)
        bar.tap()
        // Tapping doesn't select the current URL, so typing would append to it.
        let current = (bar.value as? String) ?? ""
        if current != bar.placeholderValue, !current.isEmpty {
            bar.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        bar.typeText(text + "\n")
    }

    /// Form rows are created lazily, so scroll until the element exists.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "\(element) not found after scrolling")
    }

    // MARK: - Tests

    func testDenylistedHomePageShowsBlockedBanner() {
        let app = launch(["denylist": ["example.com"], "homeURL": "https://example.com"])
        XCTAssertTrue(app.staticTexts[blockedText].waitForExistence(timeout: 5))
    }

    func testAddressBarNavigationToDenylistedSubdomainIsBlocked() {
        let app = launch(["denylist": ["example.com"]])
        go(app, to: "www.example.com")
        XCTAssertTrue(app.staticTexts[blockedText].waitForExistence(timeout: 5))
    }

    func testAllowlistBlocksUnlistedSite() {
        let app = launch(["allowlist": ["wikipedia.org"]])
        go(app, to: "example.com")
        XCTAssertTrue(app.staticTexts[blockedText].waitForExistence(timeout: 5))
    }

    func testBlockedHostAddedInSettingsTakesEffect() {
        let app = launch([:])
        app.buttons["Parent settings"].tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5))

        let blocked = app.textViews["Blocked hosts, one per line"].exists
            ? app.textViews["Blocked hosts, one per line"]
            : app.textFields["Blocked hosts, one per line"]
        scrollTo(blocked, in: app)
        blocked.tap()
        blocked.typeText("example.com")
        app.navigationBars["Parent settings"].buttons["Save"].tap()

        go(app, to: "example.com")
        XCTAssertTrue(app.staticTexts[blockedText].waitForExistence(timeout: 5))
    }

    func testUnreachableProbeShowsGateOverlay() {
        // Port 9 (discard) is closed on the host, so the probe fails fast.
        let app = launch(["probeURL": "http://127.0.0.1:9/ok"])
        XCTAssertTrue(app.staticTexts["Hearth works from home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Check again"].exists)
        XCTAssertTrue(app.buttons["Open Tailscale"].exists)
    }

    func testNoPINOpensSettingsDirectly() {
        let app = launch([:])
        app.buttons["Parent settings"].tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Parent PIN"].exists)
    }

    func testWrongPINIsRejectedAndRightPINUnlocks() {
        let app = launch(["parentPINHash": pin1234Hash])
        app.buttons["Parent settings"].tap()
        XCTAssertTrue(app.staticTexts["Parent PIN"].waitForExistence(timeout: 5))

        let field = app.secureTextFields["PIN"]
        field.tap()
        field.typeText("0000")
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.staticTexts["Wrong PIN"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Parent settings"].exists)

        field.tap()
        field.typeText("1234")
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5))
    }

    func testPINSetInSettingsIsRequiredNextTime() {
        let app = launch([:])
        app.buttons["Parent settings"].tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5))

        let pinField = app.secureTextFields["Set a PIN"]
        scrollTo(pinField, in: app)
        pinField.tap()
        pinField.typeText("1234")
        app.navigationBars["Parent settings"].buttons["Save"].tap()

        app.buttons["Parent settings"].tap()
        XCTAssertTrue(app.staticTexts["Parent PIN"].waitForExistence(timeout: 5))
    }

    /// Needs internet: Google must answer for the rewritten URL to show.
    func testSearchFromAddressBarIsForcedToSafeSearch() {
        let app = launch([:])
        go(app, to: "cats")
        let bar = addressBar(app)
        let rewritten = NSPredicate(format: "value CONTAINS 'safe=active'")
        expectation(for: rewritten, evaluatedWith: bar)
        waitForExpectations(timeout: 15)
    }
}
