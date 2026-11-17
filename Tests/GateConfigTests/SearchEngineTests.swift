import XCTest
@testable import Fort

final class SearchEngineTests: XCTestCase {

    func testSettingsParse() {
        XCTAssertEqual(SearchEngine(setting: nil), .google)
        XCTAssertEqual(SearchEngine(setting: "google"), .google)
        XCTAssertEqual(SearchEngine(setting: " Bing "), .bing)
        XCTAssertEqual(SearchEngine(setting: "DuckDuckGo"), .duckDuckGo)
        XCTAssertEqual(SearchEngine(setting: "https://search.example.com/search?q=%s"), .custom("https://search.example.com/search?q=%s"))
    }

    func testInvalidSettingsMeanGoogle() {
        for bad in ["", "yahoo", "http://search.example.com/?q=%s", "https://search.example.com/?q=",
                    "https:///?q=%s", "javascript:alert(1)//%s", "search.example.com/?q=%s"] {
            XCTAssertEqual(SearchEngine(setting: bad), .google, bad)
            XCTAssertFalse(SearchEngine.isValidSetting(bad), bad)
        }
        XCTAssertTrue(SearchEngine.isValidSetting("bing"))
        XCTAssertTrue(SearchEngine.isValidSetting("https://search.example.com/search?q=%s"))
    }

    func testSettingRoundTrips() {
        for engine in SearchEngine.builtIn + [.custom("https://search.example.com/?q=%s")] {
            XCTAssertEqual(SearchEngine(setting: engine.setting), engine)
        }
        XCTAssertNil(SearchEngine.google.setting, "Google is the default, so it isn't written out")
    }

    func testBuiltInSearchURLs() {
        XCTAssertEqual(SearchEngine.google.searchURL(for: "blue whale")?.absoluteString, "https://www.google.com/search?q=blue%20whale")
        XCTAssertEqual(SearchEngine.bing.searchURL(for: "blue whale")?.absoluteString, "https://www.bing.com/search?q=blue%20whale")
        XCTAssertEqual(SearchEngine.duckDuckGo.searchURL(for: "blue whale")?.absoluteString, "https://duckduckgo.com/?q=blue%20whale")
    }

    func testQueryCantChangeTheTemplate() {
        let url = SearchEngine.custom("https://search.example.com/search?q=%s&safe=1").searchURL(for: "cats&safe=0#x /../admin")!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.host, "search.example.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "cats&safe=0#x /../admin")
        XCTAssertEqual(items.filter { $0.name == "safe" }.map(\.value), ["1"])
        XCTAssertNil(url.fragment)
    }

    func testOnlyBuiltInEnginesGetSafeSearch() {
        XCTAssertTrue(SearchEngine.builtIn.allSatisfy(\.supportsSafeSearch))
        XCTAssertFalse(SearchEngine.custom("https://search.example.com/?q=%s").supportsSafeSearch)
        // The built-in search URLs are ones SafeSearch knows how to rewrite.
        for engine in SearchEngine.builtIn {
            XCTAssertNotNil(SafeSearch.enforced(engine.searchURL(for: "cats")!), "\(engine) should be rewritten to strict")
        }
    }

    func testAddressBarUsesTheEngineOnlyForSearches() {
        XCTAssertEqual(BrowserModel.destination(for: "cats", engine: .duckDuckGo)?.host, "duckduckgo.com")
        XCTAssertEqual(BrowserModel.destination(for: "pbskids.org", engine: .duckDuckGo)?.absoluteString, "https://pbskids.org")
        XCTAssertEqual(BrowserModel.destination(for: "cats")?.host, "www.google.com", "Google by default")
    }

    func testPickerChoicesMapToSettings() {
        XCTAssertEqual(EngineChoice(.custom("https://s.example.com/?q=%s")), .custom)
        XCTAssertEqual(EngineChoice.bing.engine(custom: "ignored").setting, "bing")
        XCTAssertNil(EngineChoice.custom.engine(custom: "not a template").setting, "an invalid custom address saves as Google")
    }

    func testHomeConfigCanSetTheEngine() {
        let keys = ["fort.config.json", "fort.homeConfig.json"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let store = ConfigStore()
        var local = GateConfig()
        local.proxy = .init(kind: .relay, host: "relay.example.com", port: 8443, authToken: "t")
        store.update(local)
        XCTAssertTrue(store.applyHome(Data(#"{"searchEngine":"duckduckgo"}"#.utf8)))
        XCTAssertEqual(SearchEngine(setting: store.config.searchEngine), .duckDuckGo)
        XCTAssertTrue(store.managedFromHome.contains("searchEngine"))
    }
}
