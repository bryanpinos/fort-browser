import SwiftUI
import WebKit
import Network
import Security

/// Shows the selected tab's WKWebView. Tabs own their web views (see
/// `TabsModel`), so switching tabs just swaps which one is on screen. The
/// policy every tab enforces lives in `Coordinator` below:
///  - all traffic pinned through an optional proxy (shared website data store)
///  - allow/deny host rules on every top-level and sub-frame navigation
///  - denylist also compiled into a WKContentRuleList so sub-resources are blocked
///  - strict safe search re-applied on each navigation
///  - no downloads; only http(s)/about schemes
///  - every decision logged
struct BrowserView: UIViewRepresentable {

    let tab: BrowserModel

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        show(tab, in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        show(tab, in: container)
    }

    private func show(_ tab: BrowserModel, in container: UIView) {
        guard let webView = tab.webView, webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
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

    final class TabCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        var config: GateConfig
        /// Whether Fort's home check currently passes (relay mode).
        var homeReachable: () -> Bool = { false }
        /// Opens a link in a new tab; returns false at the tab limit.
        var openInNewTab: (URL) -> Bool = { _ in false }
        /// Called when the tab's URL changes (to save open tabs).
        var urlChanged: () -> Void = {}
        let logger: ActivityLogger
        private var observations: [NSKeyValueObservation] = []
        /// Last URL whose page text was captured, so a full load and an
        /// in-page (SPA) URL change don't both capture the same page.
        private var lastCapturedURL: URL?
        private var spaWorkItem: DispatchWorkItem?

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
                    guard let self else { return }
                    self.model.currentURL = wv.url
                    if !self.model.showsStartPage { self.model.urlText = wv.url?.absoluteString ?? "" }
                    self.urlChanged()
                    self.noteURLChange(in: wv)
                },
                webView.observe(\.title) { [weak self] wv, _ in self?.model.title = wv.title ?? "" },
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

            if navigationAction.shouldPerformDownload {
                logger.record(url: url, allowed: false, reason: "download")
                model.blockedMessage = "Fort doesn't download files."
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame?.isMainFrame ?? true {
                lastCapturedURL = nil
                logger.record(url: url, allowed: true)
            }
            decisionHandler(.allow)
        }

        /// Title + first 2,000 characters of visible text. Runs in an isolated
        /// content world, so the page's own scripts can't see or tamper with it.
        static let pageTextScript = """
        (() => ({ title: document.title || "",
                  text: (document.body ? document.body.innerText : "").replace(/\\s+/g, " ").trim().slice(0, 2000) }))()
        """

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            capturePage(in: webView)
        }

        private func capturePage(in webView: WKWebView) {
            guard logger.wantsPageText, let url = webView.url, url != lastCapturedURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            lastCapturedURL = url
            webView.evaluateJavaScript(Self.pageTextScript, in: nil, in: .defaultClient) { [weak self] result in
                guard case .success(let value) = result, let page = value as? [String: Any] else { return }
                self?.logger.recordPage(url: url, title: page["title"] as? String ?? "",
                                        text: page["text"] as? String ?? "")
            }
        }

        /// Single-page sites (YouTube and the like) change the URL without a
        /// navigation, so decidePolicyFor/didFinish never fire. Treat a settled
        /// in-page URL change as a page view: log it and capture its text.
        /// (It can't change host, so allow/deny already applied.)
        private func noteURLChange(in webView: WKWebView) {
            spaWorkItem?.cancel()
            guard !webView.isLoading, let url = webView.url, url != lastCapturedURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView, !webView.isLoading, webView.url == url else { return }
                self.logger.record(url: url, allowed: true, reason: "in-page")
                self.capturePage(in: webView)
            }
            spaWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }

        // MARK: Downloads

        /// Fort shows pages, PDFs and images, but never downloads files.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
                return
            }
            if let url = navigationResponse.response.url {
                logger.record(url: url, allowed: false, reason: "download")
            }
            if navigationResponse.isForMainFrame {
                model.blockedMessage = "Fort doesn't download files."
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            forwarderTrace("page load failed: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
            model.isLoading = false
            let nsError = error as NSError
            let relay = config.proxy?.kind == .relay
            let failure = Self.loadFailure(code: nsError.code, relay: relay, homeReachable: homeReachable())
            if failure == .blockedAtHome, let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                logger.record(url: url, allowed: false, reason: "blocked at home")
            }
            if let message = failure?.message { model.blockedMessage = message }
        }

        enum LoadFailure: Equatable {
            case blockedAtHome, siteFailed, homeUnreachable, generic

            var message: String {
                switch self {
                case .blockedAtHome: return "This site is blocked at home."
                case .siteFailed: return "That site couldn't be opened. Try again in a little while."
                case .homeUnreachable: return "Couldn't reach home. Check Wi-Fi, and that Local Network is allowed for Fort in Settings."
                case .generic: return "Couldn't load that page."
                }
            }
        }

        /// Classifies a failed page load. With a relay and home reachable, a
        /// certificate error means the home filter answered with its block page
        /// (the UCG sinkholes blocked names and presents its own certificate).
        static func loadFailure(code: Int, relay: Bool, homeReachable: Bool) -> LoadFailure? {
            if code == NSURLErrorCancelled { return nil }
            guard relay else { return .generic }
            guard homeReachable else { return .homeUnreachable }
            let certificateErrors = [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                                     NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
                                     NSURLErrorSecureConnectionFailed]
            return certificateErrors.contains(code) ? .blockedAtHome : .siteFailed
        }

        // target="_blank" links and window.open open a new tab (through the
        // same policy as any navigation); at the tab limit, the same tab.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                if !openInNewTab(url) { webView.load(URLRequest(url: url)) }
            }
            return nil
        }
    }
}
