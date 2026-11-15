import XCTest
@testable import Fort

final class AllowsHostTests: XCTestCase {

    func testEmptyListsAllowEverything() {
        let cfg = GateConfig()
        XCTAssertTrue(cfg.allows(host: "example.com"))
        XCTAssertTrue(cfg.allows(host: "www.wikipedia.org"))
    }

    func testNilOrEmptyHostIsAllowed() {
        // about:blank, data: etc. have no host.
        var cfg = GateConfig()
        cfg.allowlist = ["wikipedia.org"]
        cfg.denylist = ["tiktok.com"]
        XCTAssertTrue(cfg.allows(host: nil))
        XCTAssertTrue(cfg.allows(host: ""))
    }

    func testDenylistBlocksExactHostAndSubdomains() {
        var cfg = GateConfig()
        cfg.denylist = ["tiktok.com"]
        XCTAssertFalse(cfg.allows(host: "tiktok.com"))
        XCTAssertFalse(cfg.allows(host: "www.tiktok.com"))
        XCTAssertFalse(cfg.allows(host: "a.b.tiktok.com"))
    }

    func testDenylistDoesNotMatchLookalikeSuffix() {
        var cfg = GateConfig()
        cfg.denylist = ["tiktok.com"]
        XCTAssertTrue(cfg.allows(host: "nottiktok.com"))
        XCTAssertTrue(cfg.allows(host: "tiktok.com.example.org"))
    }

    func testAllowlistRestrictsToListedHostsAndSubdomains() {
        var cfg = GateConfig()
        cfg.allowlist = ["wikipedia.org", "pbskids.org"]
        XCTAssertTrue(cfg.allows(host: "wikipedia.org"))
        XCTAssertTrue(cfg.allows(host: "en.wikipedia.org"))
        XCTAssertTrue(cfg.allows(host: "pbskids.org"))
        XCTAssertFalse(cfg.allows(host: "youtube.com"))
        XCTAssertFalse(cfg.allows(host: "fakewikipedia.org"))
    }

    func testDenylistWinsOverAllowlist() {
        var cfg = GateConfig()
        cfg.allowlist = ["google.com"]
        cfg.denylist = ["images.google.com"]
        XCTAssertTrue(cfg.allows(host: "www.google.com"))
        XCTAssertFalse(cfg.allows(host: "images.google.com"))
    }

    func testMatchingIsCaseInsensitiveAndTrimsPatterns() {
        var cfg = GateConfig()
        cfg.denylist = ["  Reddit.COM  ", ""]
        XCTAssertFalse(cfg.allows(host: "WWW.REDDIT.com"))
        XCTAssertTrue(cfg.allows(host: "example.com"), "empty pattern must not match everything")
    }
}

final class SafeSearchTests: XCTestCase {

    private func query(_ url: URL?, _ name: String) -> String? {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return c.queryItems?.first(where: { $0.name == name })?.value
    }

    func testGoogleSearchGetsSafeActive() {
        let out = SafeSearch.enforced(URL(string: "https://www.google.com/search?q=cats")!)
        XCTAssertEqual(query(out, "safe"), "active")
        XCTAssertEqual(query(out, "q"), "cats")
    }

    func testGoogleCountryDomain() {
        let out = SafeSearch.enforced(URL(string: "https://www.google.co.uk/search?q=cats")!)
        XCTAssertEqual(query(out, "safe"), "active")
    }

    func testGoogleSafeOffIsOverridden() {
        let out = SafeSearch.enforced(URL(string: "https://www.google.com/search?q=cats&safe=off")!)
        XCTAssertEqual(query(out, "safe"), "active")
    }

    func testAlreadyStrictGoogleReturnsNil() {
        // nil means "no rewrite needed"; returning a URL here would loop.
        XCTAssertNil(SafeSearch.enforced(URL(string: "https://www.google.com/search?q=cats&safe=active")!))
    }

    func testGoogleNonSearchPathUntouched() {
        XCTAssertNil(SafeSearch.enforced(URL(string: "https://www.google.com/maps")!))
    }

    func testBingSearchAndImagesGetAdltStrict() {
        let search = SafeSearch.enforced(URL(string: "https://www.bing.com/search?q=cats")!)
        XCTAssertEqual(query(search, "adlt"), "strict")
        let images = SafeSearch.enforced(URL(string: "https://www.bing.com/images/search?q=cats")!)
        XCTAssertEqual(query(images, "adlt"), "strict")
        XCTAssertNil(SafeSearch.enforced(URL(string: "https://www.bing.com/search?q=cats&adlt=strict")!))
    }

    func testDuckDuckGoGetsKp1() {
        let out = SafeSearch.enforced(URL(string: "https://duckduckgo.com/?q=cats&kp=-2")!)
        XCTAssertEqual(query(out, "kp"), "1")
        XCTAssertNil(SafeSearch.enforced(URL(string: "https://duckduckgo.com/?q=cats&kp=1")!))
    }

    func testYouTubeAndOtherHostsUntouched() {
        XCTAssertNil(SafeSearch.enforced(URL(string: "https://www.youtube.com/results?search_query=cats")!))
        XCTAssertNil(SafeSearch.enforced(URL(string: "https://www.wikipedia.org/")!))
    }

    func testHostMatchIsCaseInsensitive() {
        let out = SafeSearch.enforced(URL(string: "https://WWW.GOOGLE.COM/search?q=cats")!)
        XCTAssertEqual(query(out, "safe"), "active")
    }

    func testFreshInstallHasAStarterBlockList() {
        XCTAssertFalse(GateConfig.default.allows(host: "www.pornhub.com"))
        XCTAssertTrue(GateConfig.default.allows(host: "pbskids.org"))
        XCTAssertFalse(GateConfig.default.favorites?.isEmpty ?? true)
        XCTAssertTrue(GateConfig().allows(host: "www.pornhub.com"), "only a fresh install gets the starter list")
    }
}
