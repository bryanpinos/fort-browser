import XCTest
@testable import Fort

/// The home config (control plane) layered over the iPad's own settings.
final class HomeConfigTests: XCTestCase {
    private let keys = ["fort.config.json", "fort.homeConfig.json"]

    override func setUp() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func storeWithRelay() -> ConfigStore {
        let store = ConfigStore()
        var local = GateConfig()
        local.proxy = .init(kind: .relay, host: "relay.example.com", port: 8443, authToken: "local-token")
        local.denylist = ["local.example"]
        store.update(local)
        return store
    }

    func testHomeFieldsReplaceLocalOnes() {
        let store = storeWithRelay()
        XCTAssertTrue(store.applyHome(json(#"{"denylist":["home.example"],"reviewPages":true,"favorites":[{"name":"Fort Chat","url":"https://kids-chat.example.com"}]}"#)))
        XCTAssertEqual(store.config.denylist, ["home.example"])
        XCTAssertEqual(store.config.reviewPages, true)
        XCTAssertEqual(store.config.favorites?.first?.name, "Fort Chat")
        XCTAssertEqual(store.managedFromHome, ["denylist", "reviewPages", "favorites"])
        XCTAssertEqual(store.config.proxy?.host, "relay.example.com", "untouched fields stay local")
    }

    func testHomeCanNeverChangeTheRelayConnection() {
        let store = storeWithRelay()
        XCTAssertTrue(store.applyHome(json(#"{"proxy":{"kind":"relay","host":"evil.example","port":1},"reviewPages":true}"#)))
        XCTAssertEqual(store.config.proxy?.host, "relay.example.com")
        XCTAssertEqual(store.config.proxy?.authToken, "local-token")
        XCTAssertFalse(store.managedFromHome.contains("proxy"))
    }

    func testBrokenHomeConfigChangesNothing() {
        let store = storeWithRelay()
        store.applyHome(json(#"{"denylist":["good.example"]}"#))
        for bad in ["not json", "[1,2]", #"{"denylist": 5}"#, #"{"homeURL": "not a url at all with spaces"}"#,
                    #"{"favorites":[{"name":"x","url":"javascript:alert(1)"}]}"#] {
            XCTAssertFalse(store.applyHome(json(bad)), bad)
            XCTAssertEqual(store.config.denylist, ["good.example"], "kept the last good config after \(bad)")
        }
    }

    func testHomeConfigSurvivesRelaunch() {
        let store = storeWithRelay()
        store.applyHome(json(#"{"denylist":["home.example"]}"#))
        let relaunched = ConfigStore()
        XCTAssertEqual(relaunched.config.denylist, ["home.example"])
        XCTAssertEqual(relaunched.managedFromHome, ["denylist"])
        XCTAssertEqual(relaunched.config.proxy?.host, "relay.example.com")
    }

    func testLocalEditsDontOverrideManagedFields() {
        let store = storeWithRelay()
        store.applyHome(json(#"{"denylist":["home.example"]}"#))
        var edited = store.config
        edited.denylist = []
        edited.homeURL = URL(string: "https://pbskids.org")!
        store.update(edited)
        XCTAssertEqual(store.config.denylist, ["home.example"], "managed from home")
        XCTAssertEqual(store.config.homeURL.host, "pbskids.org", "unmanaged fields still edit locally")
    }

    func testEachFetchReplacesTheWholeHomeLayer() {
        let store = storeWithRelay()
        store.applyHome(json(#"{"denylist":["home.example"],"reviewPages":true}"#))
        store.applyHome(json(#"{"reviewPages":true}"#))
        XCTAssertEqual(store.config.denylist, ["local.example"], "a field dropped from fort.json goes back to the iPad's own value")
        XCTAssertEqual(store.managedFromHome, ["reviewPages"])
    }

    func testConfigURLIsBesideTheHealthCheck() {
        let proxy = GateConfig.ProxyConfig(kind: .relay, host: "relay.example.com", port: 8443, authToken: "t")
        XCTAssertEqual(NetworkGate.relayConfigURL(for: proxy)?.absoluteString, "https://relay.example.com:8443/fort/config")
    }
}
