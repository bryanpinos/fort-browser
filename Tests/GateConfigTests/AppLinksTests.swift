import XCTest
@testable import Fort

final class AppLinksTests: XCTestCase {

    private func decide(_ s: String, _ allowed: [String]? = ["roblox"]) -> AppLinks.Decision {
        AppLinks.decision(for: URL(string: s)!, allowed: allowed)
    }

    func testWebLinksAreLeftToTheNormalChecks() {
        XCTAssertEqual(decide("https://www.roblox.com/home"), .web)
        XCTAssertEqual(decide("HTTP://example.com"), .web)
        XCTAssertEqual(decide("about:blank"), .web)
    }

    func testAllowedAppAsksFirst() {
        // What Roblox's sign-in page does to return to the app.
        XCTAssertEqual(decide("roblox://navigation"), .ask(app: "Roblox"))
        XCTAssertEqual(decide("ROBLOX://navigation", ["Roblox://"]), .ask(app: "Roblox"))
    }

    func testOtherAppsAreRefusedWithAName() {
        XCTAssertEqual(decide("roblox://navigation", nil), .notAllowed(app: "Roblox"))
        XCTAssertEqual(decide("roblox://navigation", []), .notAllowed(app: "Roblox"))
        XCTAssertEqual(decide("minecraft://x"), .notAllowed(app: "Minecraft"))
        XCTAssertEqual(decide("tel:5551234"), .notAllowed(app: "Tel"))
    }

    func testBrowsersShortcutsSettingsAndInstallsAreNeverOpened() {
        let risky = ["googlechromes://example.com", "firefox://open-url?url=x", "x-safari-https://example.com",
                     "shortcuts://run-shortcut?name=x", "prefs:root=General", "App-prefs:WIFI",
                     "itms-apps://apps.apple.com/app/id1", "itms-services://?action=download-manifest"]
        for link in risky {
            let scheme = String(link.prefix { $0 != ":" })
            guard case .notAllowed = decide(link, [scheme]) else {
                return XCTFail("\(link) must never be opened, even when listed")
            }
        }
    }

    func testPageInternalSchemesAreRefusedQuietly() {
        for link in ["data:text/html,hi", "blob:https://example.com/1", "javascript:alert(1)", "file:///etc/passwd"] {
            XCTAssertEqual(decide(link, ["data", "blob", "javascript", "file"]), .refuse, link)
        }
    }

    func testNormalize() {
        XCTAssertEqual(AppLinks.normalize(" Roblox:// "), "roblox")
        XCTAssertEqual(AppLinks.normalize("roblox:"), "roblox")
        XCTAssertEqual(AppLinks.normalize("com.example.app"), "com.example.app")
        for bad in ["", "https", "about", "data", "1abc", "has space", "a/b"] {
            XCTAssertNil(AppLinks.normalize(bad), bad)
        }
    }

    func testSettingsFieldParsing() {
        XCTAssertEqual(AppLinksEditor.parse("Roblox\nroblox://\n\nminecraft\nfirefox\nhttps"), ["roblox", "minecraft"])
        XCTAssertEqual(AppLinksEditor.refused("roblox\nfirefox\nnot a scheme"), ["firefox", "not a scheme"])
    }

    func testHomeConfigCanSetAppLinks() {
        let keys = ["fort.config.json", "fort.homeConfig.json"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let store = ConfigStore()
        var local = GateConfig()
        local.proxy = .init(kind: .relay, host: "relay.example.com", port: 8443, authToken: "t")
        store.update(local)
        XCTAssertTrue(store.applyHome(Data(#"{"appLinks":["roblox"]}"#.utf8)))
        XCTAssertEqual(store.config.appLinks, ["roblox"])
        XCTAssertTrue(store.managedFromHome.contains("appLinks"))
    }
}
