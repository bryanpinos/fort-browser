import XCTest

/// App Store screenshots. Skipped unless a folder is given:
///   TEST_RUNNER_FORT_SCREENSHOTS_DIR=/tmp/fort-shots xcodebuild test -scheme Fort \
///     -only-testing:FortUITests/AppStoreScreenshots -destination '…iPad Pro 13-inch…'
/// Set the simulator's status bar first (`xcrun simctl status_bar booted override --time 9:41 …`).
final class AppStoreScreenshots: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        let dir = ProcessInfo.processInfo.environment["FORT_SCREENSHOTS_DIR"] ?? ""
        try XCTSkipIf(dir.isEmpty, "set TEST_RUNNER_FORT_SCREENSHOTS_DIR to make screenshots")
        folder = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private let favorites: [[String: String]] = [
        ["name": "PBS Kids", "url": "https://pbskids.org"],
        ["name": "NASA Space Place", "url": "https://spaceplace.nasa.gov"],
        ["name": "Nat Geo Kids", "url": "https://kids.nationalgeographic.com"],
        ["name": "Wikipedia", "url": "https://www.wikipedia.org"],
        ["name": "Khan Academy", "url": "https://www.khanacademy.org"],
        ["name": "Scratch", "url": "https://scratch.mit.edu"],
        ["name": "Smithsonian", "url": "https://www.si.edu/kids"],
        ["name": "Fort Chat", "url": "https://chat.example.com"],
        ["name": "Code.org", "url": "https://code.org"],
        ["name": "Library", "url": "https://www.loc.gov/families/"],
    ]

    private func launch(_ config: [String: Any], tabs: [String] = []) -> XCUIApplication {
        var cfg: [String: Any] = ["probeIntervalSeconds": 15, "allowlist": [String](), "denylist": [String](),
                                  "enforceSafeSearch": true, "homeURL": "about:blank", "favorites": favorites]
        cfg.merge(config) { _, new in new }
        let hex = try! JSONSerialization.data(withJSONObject: cfg).map { String(format: "%02x", $0) }.joined()
        let app = XCUIApplication()
        app.launchArguments = ["-fort.config.json", "<\(hex)>", "-fort.deviceName", "",
                               "-fort.noTabRestore", "YES", "-fort.kidFavorites", "<>"]
        app.launch()
        return app
    }

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func startPage(_ app: XCUIApplication) {
        // The first tab opens the home page; swap it for a start-page tab.
        app.buttons["New tab"].tap()
        app.buttons["Close tab"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Where to?"].waitForExistence(timeout: 5))
    }

    func test1StartPage() {
        let app = launch([:])
        startPage(app)
        sleep(2)
        shoot("1-start-page")
    }

    func test2Browsing() {
        let app = launch(["homeURL": "https://spaceplace.nasa.gov/"])
        // Two more tabs behind the page, as a kid would have.
        app.buttons["New tab"].tap()
        app.buttons["PBS Kids"].tap()
        sleep(3)
        app.buttons["New tab"].tap()
        app.buttons["Wikipedia"].tap()
        sleep(3)
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'NASA'")).firstMatch.tap()
        sleep(6)
        shoot("2-browsing")
    }

    func test3Blocked() {
        let app = launch(["denylist": ["games.example.com"]])
        startPage(app)
        let bar = app.textFields["Search or enter a site"]
        bar.tap()
        bar.typeText("games.example.com\n")
        XCTAssertTrue(app.staticTexts["This one stays outside the fort"].waitForExistence(timeout: 10))
        sleep(1)
        shoot("3-blocked")
    }

    func test4WorksFromHome() {
        let app = launch(["proxy": ["kind": "relay", "host": "10.255.255.1", "port": 8443, "authToken": "t"]])
        XCTAssertTrue(app.staticTexts["Fort works from home"].waitForExistence(timeout: 10))
        // Wait out "Checking…" for the message a kid actually sees.
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'only works at home'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 60))
        sleep(1)
        shoot("4-works-from-home")
    }

    func test5ParentSettings() {
        let app = launch(["denylist": ["games.example.com", "videos.example.com"]])
        startPage(app)
        app.buttons["Parent settings"].tap()
        XCTAssertTrue(app.navigationBars["Parent settings"].waitForExistence(timeout: 5))
        // Down to the Sites section, in small steps, until the search-engine row
        // is on screen: block list, SafeSearch and the search engine together.
        let form = app.collectionViews.firstMatch
        let engine = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Search with'")).firstMatch
        for _ in 0..<20 {
            if engine.exists, engine.frame.minY > form.frame.minY, engine.frame.maxY < form.frame.maxY - 60 { break }
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        }
        sleep(1)
        shoot("5-parent-settings")
    }
}
