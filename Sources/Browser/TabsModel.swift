import Foundation
import Network
import Observation
import WebKit

/// Fort's tabs. Every tab's web view is built here with the same safety
/// configuration (proxy via the shared website data store, denylist content
/// rules, the navigation-policy delegate), so a new tab can never be a way
/// around the parent's settings.
@Observable
final class TabsModel {

    static let maxTabs = 8
    private static let savedTabsKey = "fort.openTabs"
    private static let savedSelectionKey = "fort.selectedTab"
    /// Launch argument for tests: start with one fresh tab, ignore saved tabs.
    private static let noRestoreKey = "fort.noTabRestore"

    private(set) var tabs: [BrowserModel] = []
    var selectedID: UUID?

    @ObservationIgnored private var config: GateConfig
    @ObservationIgnored private let logger: ActivityLogger
    @ObservationIgnored private let homeReachable: () -> Bool

    init(config: GateConfig, logger: ActivityLogger, homeReachable: @escaping () -> Bool) {
        self.config = config
        self.logger = logger
        self.homeReachable = homeReachable
        restore()
    }

    var selected: BrowserModel {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    var canOpenTab: Bool { tabs.count < Self.maxTabs }

    // MARK: - Tabs

    /// Opens a tab with `url`, or the favorites start page when nil.
    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true) -> BrowserModel? {
        guard canOpenTab else { return nil }
        let tab = makeTab()
        tabs.append(tab)
        if let url { tab.load(url: url) } else { tab.showStartPage() }
        if select { selectedID = tab.id }
        save()
        return tab
    }

    func select(_ tab: BrowserModel) {
        selectedID = tab.id
        save()
    }

    /// Closing the last tab leaves a fresh start page rather than no tabs.
    func close(_ tab: BrowserModel) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.webView?.stopLoading()
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab()
            return
        }
        if selectedID == tab.id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        save()
    }

    // MARK: - Config and network

    func apply(config: GateConfig) {
        guard config != self.config else { return }
        self.config = config
        for tab in tabs {
            tab.coordinator?.config = config
            if let webView = tab.webView { tab.coordinator?.installContentRules(on: webView) }
        }
    }

    /// All tabs share the default website data store, so its proxy covers
    /// every tab at once.
    func applyProxies(forwarder: RelayForwarder, identities: ClientIdentityStore) {
        WKWebsiteDataStore.default().proxyConfigurations =
            Self.webKitProxies(config: config, forwarder: forwarder, hasIdentity: identities.hasIdentity)
    }

    /// What WebKit itself should use as its proxy.
    static func webKitProxies(config: GateConfig, forwarder: RelayForwarder, hasIdentity: Bool) -> [ProxyConfiguration] {
        guard let proxy = config.proxy else { return [] }
        guard BrowserView.usesForwarder(proxy, hasIdentity: hasIdentity) else {
            return [BrowserView.proxyConfiguration(for: proxy, identity: nil)]
        }
        // WebKit can't present client certs to a relay, so it goes through the
        // in-app forwarder. Until that's listening, point at a closed loopback
        // port (9, discard) so nothing loads.
        let port = forwarder.port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? 9
        var local = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
        local.applyCredential(username: forwarder.username, password: forwarder.password)
        local.allowFailover = false
        return [local]
    }

    // MARK: - Building a tab

    private func makeTab() -> BrowserModel {
        let tab = BrowserModel()
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // iPad gets desktop sites, phones mobile ones (Safari's default).
        configuration.defaultWebpagePreferences.preferredContentMode = .recommended
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let coordinator = BrowserView.TabCoordinator(model: tab, config: config, logger: logger)
        coordinator.homeReachable = homeReachable
        coordinator.openInNewTab = { [weak self] url in
            guard let self else { return false }
            return self.newTab(url: url) != nil
        }
        coordinator.urlChanged = { [weak self] in self?.save() }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        coordinator.attach(webView)
        coordinator.installContentRules(on: webView)

        tab.webView = webView
        tab.coordinator = coordinator
        return tab
    }

    // MARK: - Saving and restoring open tabs

    private func save() {
        let urls = tabs.map { $0.showsStartPage ? "" : ($0.currentURL?.absoluteString ?? "") }
        UserDefaults.standard.set(urls, forKey: Self.savedTabsKey)
        UserDefaults.standard.set(tabs.firstIndex { $0.id == selectedID } ?? 0, forKey: Self.savedSelectionKey)
    }

    /// iPadOS kills background apps, so reopen what the kid had open. With
    /// nothing saved (first launch), open the home page.
    private func restore() {
        let defaults = UserDefaults.standard
        let saved = defaults.bool(forKey: Self.noRestoreKey) ? [] : (defaults.stringArray(forKey: Self.savedTabsKey) ?? [])
        for entry in saved.prefix(Self.maxTabs) {
            let tab = makeTab()
            tabs.append(tab)
            if let url = URL(string: entry), url.host != nil { tab.load(url: url) } else { tab.showStartPage() }
        }
        if tabs.isEmpty {
            let tab = makeTab()
            tabs.append(tab)
            tab.load(url: config.homeURL)
        }
        let index = min(max(0, defaults.integer(forKey: Self.savedSelectionKey)), tabs.count - 1)
        selectedID = tabs[index].id
    }
}
