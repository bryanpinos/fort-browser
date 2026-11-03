import XCTest
@testable import Fort

final class FavoritesStoreTests: XCTestCase {
    private var store: FavoritesStore!
    private var key: String!

    override func setUp() {
        key = "fort.tests.favorites.\(UUID().uuidString)"
        store = FavoritesStore(key: key)
    }

    override func tearDown() { UserDefaults.standard.removeObject(forKey: key) }

    func testToggleAddsThenRemovesAndPersists() {
        let url = URL(string: "https://www.pbskids.org/games")!
        store.toggle(url, title: "PBS KIDS Games")
        XCTAssertTrue(store.isFavorite(url, parent: nil))
        XCTAssertEqual(FavoritesStore(key: key).kidFavorites.first?.name, "PBS KIDS Games")
        store.toggle(URL(string: "https://pbskids.org/games/")!, title: "")
        XCTAssertFalse(store.isFavorite(url, parent: nil), "www, scheme and trailing slash don't matter")
    }

    func testParentFavoritesComeFirstWithoutDuplicates() {
        let parent = [GateConfig.Favorite(name: "Wikipedia", url: URL(string: "https://www.wikipedia.org/")!)]
        store.toggle(URL(string: "https://wikipedia.org")!, title: "Wiki")
        store.toggle(URL(string: "https://nasa.gov")!, title: "NASA")
        let all = store.all(parent: parent)
        XCTAssertEqual(all.map(\.favorite.name), ["Wikipedia", "NASA"])
        XCTAssertEqual(all.map(\.isKids), [false, true])
    }

    func testParseAndFormatRoundTrip() {
        let parsed = FavoritesStore.parse("pbskids.org PBS Kids\nhttps://www.nasa.gov/ NASA\n\nnot a site at all\nexample.com")
        XCTAssertEqual(parsed.map(\.name), ["PBS Kids", "NASA", "example.com"])
        XCTAssertEqual(parsed.first?.url.absoluteString, "https://pbskids.org")
        XCTAssertEqual(FavoritesStore.parse(FavoritesStore.format(parsed)), parsed)
    }
}

@MainActor
final class TabsModelTests: XCTestCase {

    private func makeTabs() -> TabsModel {
        UserDefaults.standard.set(true, forKey: "fort.noTabRestore")
        return TabsModel(config: GateConfig(), logger: ActivityLogger(endpoint: nil), homeReachable: { true })
    }

    override func tearDown() { UserDefaults.standard.removeObject(forKey: "fort.noTabRestore") }

    func testStartsWithOneTabOnTheHomePage() {
        let tabs = makeTabs()
        XCTAssertEqual(tabs.tabs.count, 1)
        XCTAssertFalse(tabs.selected.showsStartPage)
        XCTAssertNotNil(tabs.selected.webView)
    }

    func testEveryTabGetsTheSafetyDelegate() {
        let tabs = makeTabs()
        let tab = tabs.newTab()!
        XCTAssertTrue(tab.webView?.navigationDelegate === tab.coordinator, "a new tab must enforce the same policy")
        XCTAssertTrue(tab.webView?.uiDelegate === tab.coordinator)
        XCTAssertTrue(tab.showsStartPage)
        XCTAssertEqual(tabs.selectedID, tab.id)
    }

    func testLimitAndClose() {
        let tabs = makeTabs()
        while tabs.canOpenTab { tabs.newTab() }
        XCTAssertEqual(tabs.tabs.count, TabsModel.maxTabs)
        XCTAssertNil(tabs.newTab())
        let middle = tabs.tabs[3]
        tabs.select(middle)
        tabs.close(middle)
        XCTAssertEqual(tabs.tabs.count, TabsModel.maxTabs - 1)
        XCTAssertNotEqual(tabs.selectedID, middle.id)
        for tab in tabs.tabs { tabs.close(tab) }
        XCTAssertEqual(tabs.tabs.count, 1, "never zero tabs")
        XCTAssertTrue(tabs.selected.showsStartPage)
    }

    func testConfigChangesReachEveryTab() {
        let tabs = makeTabs()
        tabs.newTab()
        var config = GateConfig()
        config.denylist = ["example.com"]
        tabs.apply(config: config)
        for tab in tabs.tabs { XCTAssertEqual(tab.coordinator?.config.denylist, ["example.com"]) }
    }
}
