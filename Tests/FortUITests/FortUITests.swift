import XCTest

/// Drives the real app UI. Each test injects its GateConfig through the
/// UserDefaults argument domain (`-fort.config.json <hex>`), which overrides
/// whatever an earlier run saved, so no test hooks are needed in the app.
final class FortUITests: XCTestCase {

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
        app.launchArguments = ["-fort.config.json", "<\(hex)>", "-fort.deviceName", "",
                              // Isolation: no tabs or kid favorites carried over from earlier tests.
                              "-fort.noTabRestore", "YES", "-fort.kidFavorites", "<>"]
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
        XCTAssertTrue(app.staticTexts["Fort works from home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Check again"].exists)
        XCTAssertTrue(app.buttons["Open Tailscale"].exists)
    }

    func testUnreachableRelayShowsHomeOverlayWithoutVPNAdvice() {
        let app = launch(["proxy": ["kind": "relay", "host": "10.255.255.1", "port": 8443, "authToken": "t"]])
        XCTAssertTrue(app.staticTexts["Fort works from home"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Check again"].exists)
        XCTAssertFalse(app.buttons["Open Tailscale"].exists, "relay mode shouldn't suggest a VPN")
        app.buttons["gate-parent-settings"].tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5),
                      "settings must stay reachable while the gate is closed")
    }

    func testTappingTheAddressBarSelectsItSoTypingReplaces() {
        let app = launch(["homeURL": "https://example.com/"])
        let bar = addressBar(app)
        let filled = NSPredicate(format: "value BEGINSWITH 'https://example.com'")
        expectation(for: filled, evaluatedWith: bar)
        waitForExpectations(timeout: 15)
        bar.tap()
        bar.typeText("dogs")
        XCTAssertEqual(bar.value as? String, "dogs", "typing should replace the selected address, not append to it")
    }

    func testClearButtonEmptiesTheAddressBar() {
        let app = launch([:])
        let bar = addressBar(app)
        bar.tap()
        bar.typeText("cats and dogs")
        let clear = app.buttons["Clear address"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.tap()
        let value = (bar.value as? String) ?? ""
        XCTAssertTrue(value.isEmpty || value == bar.placeholderValue, "address bar should be empty, got \(value)")
        XCTAssertFalse(app.buttons["Clear address"].exists, "button hides when there's nothing to clear")
        bar.typeText("x")
        XCTAssertEqual(bar.value as? String, "x", "keyboard stays up after clearing")
    }

    // MARK: Tabs and favorites

    private var tabs: XCUIElementQuery { XCUIApplication().buttons.matching(identifier: "tab") }

    func testNewTabOpensStartPageAndClosingKeepsOneTab() {
        let app = launch([:])
        XCTAssertEqual(tabs.count, 1)
        app.buttons["New tab"].tap()
        XCTAssertEqual(tabs.count, 2)
        XCTAssertTrue(app.staticTexts["Where to?"].waitForExistence(timeout: 5))
        app.buttons["Close tab"].firstMatch.tap()
        XCTAssertEqual(tabs.count, 1)
        app.buttons["Close tab"].firstMatch.tap()
        XCTAssertEqual(tabs.count, 1, "closing the last tab leaves a fresh start page")
        XCTAssertTrue(app.staticTexts["Where to?"].waitForExistence(timeout: 5))
    }

    func testTabLimit() {
        let app = launch([:])
        for _ in 1..<8 { app.buttons["New tab"].tap() }
        XCTAssertEqual(tabs.count, 8)
        XCTAssertFalse(app.buttons["New tab"].isEnabled, "8 tabs is the limit")
    }

    func testParentFavoritesShowOnTheStartPageAndOpen() {
        let app = launch(["favorites": [["name": "Example", "url": "https://example.com/"]]])
        app.buttons["New tab"].tap()
        let tile = app.buttons["Example"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        let opened = NSPredicate(format: "value BEGINSWITH 'https://example.com'")
        expectation(for: opened, evaluatedWith: addressBar(app))
        waitForExpectations(timeout: 15)
    }

    func testStarAddsTheSiteToTheStartPage() {
        let app = launch(["homeURL": "https://example.com/"])
        let star = app.buttons["Favorite"]
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: star)
        waitForExpectations(timeout: 15)
        star.tap()
        app.buttons["New tab"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "favorite-tile").firstMatch.waitForExistence(timeout: 5),
                      "starred site should appear as a tile")
    }

    func testParentSettingsOffersWebsiteDataClearing() {
        let app = launch([:])
        app.buttons["Parent settings"].tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5))
        let clearCache = app.buttons["Clear cache (keeps sign-ins)"]
        scrollTo(clearCache, in: app)
        XCTAssertTrue(app.buttons["Clear all website data…"].exists)
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

    func testDeviceNameIsSavedFromSettings() {
        let app = launch([:])
        app.buttons["Parent settings"].tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5))

        let field = app.textFields["Device name (e.g. Ava's iPad)"]
        scrollTo(field, in: app)
        field.tap()
        field.typeText("Ava's iPad")
        app.navigationBars["Parent settings"].buttons["Save"].tap()

        app.buttons["Parent settings"].tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5))
        let reopened = app.textFields["Device name (e.g. Ava's iPad)"]
        scrollTo(reopened, in: app)
        XCTAssertEqual(reopened.value as? String, "Ava's iPad")
    }

    func testRelaySettingsShowTokenAndCertificateSection() {
        let app = launch(["proxy": ["kind": "relay", "host": "relay.example.com", "port": 8443]])
        // The relay is unreachable, so the gate is closed: use the overlay's button.
        let grownUps = app.buttons["gate-parent-settings"]
        XCTAssertTrue(grownUps.waitForExistence(timeout: 20))
        grownUps.tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5))
        let token = app.secureTextFields["Relay token"]
        scrollTo(token, in: app)
        let importButton = app.buttons["Import certificate…"]
        let replaceButton = app.buttons["Replace certificate…"]
        if !importButton.exists && !replaceButton.exists { scrollTo(importButton, in: app) }
        XCTAssertTrue(importButton.exists || replaceButton.exists, "certificate section missing")
        // Page review is offered (off by default) only in relay mode.
        let review = app.switches["Send page text home for review"]
        scrollTo(review, in: app)
        XCTAssertEqual(review.value as? String, "0", "page review must default to off")
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
