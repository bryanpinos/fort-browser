import SwiftUI
import WebKit
import Network
import Security

/// SwiftUI wrapper around WKWebView that enforces the parent's config:
///  - all traffic pinned through an optional proxy (WKWebsiteDataStore.proxyConfigurations)
///  - allow/deny host rules on every top-level and sub-frame navigation
///  - denylist additionally compiled into a WKContentRuleList so sub-resources are blocked too
///  - strict safe search re-applied on each navigation
///  - every decision logged
struct BrowserView: UIViewRepresentable {

    let model: BrowserModel
    let config: GateConfig
    let logger: ActivityLogger
    let forwarder: RelayForwarder
    let identities: ClientIdentityStore

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, config: config, logger: logger)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let store = WKWebsiteDataStore.default()
        store.proxyConfigurations = webKitProxies()
        context.coordinator.appliedForwarderPort = forwarder.port
        context.coordinator.appliedHasIdentity = identities.hasIdentity
        configuration.websiteDataStore = store

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = nil

        context.coordinator.attach(webView)
        context.coordinator.installContentRules(on: webView)

        model.webView = webView
        webView.load(URLRequest(url: config.homeURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let configChanged = coordinator.config != config
        if configChanged || coordinator.appliedForwarderPort != forwarder.port
            || coordinator.appliedHasIdentity != identities.hasIdentity {
            coordinator.config = config
            coordinator.appliedForwarderPort = forwarder.port
            coordinator.appliedHasIdentity = identities.hasIdentity
            webView.configuration.websiteDataStore.proxyConfigurations = webKitProxies()
        }
        if configChanged {
            coordinator.installContentRules(on: webView)
        }
    }

    /// What WebKit itself should use as its proxy.
    private func webKitProxies() -> [ProxyConfiguration] {
        guard let proxy = config.proxy else { return [] }
        guard Self.usesForwarder(proxy, hasIdentity: identities.hasIdentity) else {
            return [Self.proxyConfiguration(for: proxy, identity: nil)]
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

    /// A relay plus an installed client certificate needs the in-app forwarder.
    /// Without a certificate WebKit uses the relay hop directly (token only);
    /// a relay that requires mTLS then refuses it, which fails closed.
    static func usesForwarder(_ proxy: GateConfig.ProxyConfig, hasIdentity: Bool) -> Bool {
        proxy.kind == .relay && hasIdentity
    }

    /// The proxy as the parent configured it. For an mTLS relay this is what
    /// the forwarder dials; WebKit never sees it.
    static func proxyConfiguration(for proxy: GateConfig.ProxyConfig, identity: SecIdentity?) -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host),
                                           port: NWEndpoint.Port(rawValue: proxy.port) ?? 8080)
        var configuration: ProxyConfiguration
        switch proxy.kind {
        case .socks5: configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http:   configuration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .relay:
            let headers = proxy.authToken.map { ["x-fort-token": $0] } ?? [:]
            let tls = NWProtocolTLS.Options()
            if let identity, let secIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            }
            configuration = ProxyConfiguration(relayHops: [
                .init(http2RelayEndpoint: endpoint, tlsOptions: tls, additionalHTTPHeaderFields: headers),
            ])
        }
        // Fail closed: never fall back to a direct connection if the proxy fails.
        configuration.allowFailover = false
        return configuration
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        var config: GateConfig
        var appliedForwarderPort: UInt16?
        var appliedHasIdentity = false
        let logger: ActivityLogger
        private var observations: [NSKeyValueObservation] = []

        init(model: BrowserModel, config: GateConfig, logger: ActivityLogger) {
            self.model = model
            self.config = config
            self.logger = logger
        }

        func attach(_ webView: WKWebView) {
            observations = [
                webView.observe(\.canGoBack) { [weak self] wv, _ in self?.model.canGoBack = wv.canGoBack },
                webView.observe(\.canGoForward) { [weak self] wv, _ in self?.model.canGoForward = wv.canGoForward },
                webView.observe(\.isLoading) { [weak self] wv, _ in self?.model.isLoading = wv.isLoading },
                webView.observe(\.estimatedProgress) { [weak self] wv, _ in self?.model.progress = wv.estimatedProgress },
                webView.observe(\.url) { [weak self] wv, _ in
                    self?.model.currentURL = wv.url
                    self?.model.urlText = wv.url?.absoluteString ?? ""
                },
            ]
        }

        /// Compile the denylist into WebKit's content blocker so blocked hosts
        /// can't even be loaded as images/scripts/iframes inside allowed pages.
        func installContentRules(on webView: WKWebView) {
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            guard !config.denylist.isEmpty else { return }

            let rules: [[String: Any]] = config.denylist.map { host in
                let escaped = NSRegularExpression.escapedPattern(for: host.lowercased())
                // WebKit's content-blocker regex has no alternation, so `(/|$)` is
                // rejected. URLs are normalized with a path, so the host is always
                // followed by a port or a slash.
                return [
                    "trigger": ["url-filter": "^[a-z]+://([^/]*\\.)?\(escaped)[:/]", "url-filter-is-case-sensitive": false],
                    "action": ["type": "block"],
                ]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: rules),
                  let json = String(data: data, encoding: .utf8) else { return }

            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "fort.denylist",
                                                                    encodedContentRuleList: json) { list, error in
                if let list { controller.add(list) }
                else if let error { print("Content rule compile failed: \(error)") }
            }
        }

        // MARK: Navigation policy

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }

            // Only http(s) and about: are allowed; no tel:, sms:, itms-apps: etc.
            if let scheme = url.scheme?.lowercased(), !["http", "https", "about"].contains(scheme) {
                logger.record(url: url, allowed: false, reason: "scheme")
                decisionHandler(.cancel)
                return
            }

            if !config.allows(host: url.host) {
                logger.record(url: url, allowed: false, reason: "blocked host")
                if navigationAction.targetFrame?.isMainFrame ?? true {
                    model.blockedMessage = "That site isn't on the allowed list."
                }
                decisionHandler(.cancel)
                return
            }

            if config.enforceSafeSearch,
               navigationAction.targetFrame?.isMainFrame ?? true,
               let rewritten = SafeSearch.enforced(url) {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: rewritten))
                return
            }

            if navigationAction.targetFrame?.isMainFrame ?? true {
                logger.record(url: url, allowed: true)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            forwarderTrace("page load failed: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
            model.isLoading = false
            let nsError = error as NSError
            if nsError.code != NSURLErrorCancelled {
                model.blockedMessage = config.proxy?.kind == .relay
                    ? "Couldn't reach home. Check Wi-Fi, and that Local Network is allowed for Fort in Settings."
                    : "Couldn't load that page."
            }
        }

        // Open target="_blank" links in the same view instead of a popup.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
