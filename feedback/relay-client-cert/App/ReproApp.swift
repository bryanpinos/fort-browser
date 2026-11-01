import SwiftUI
import WebKit
import Network
import Security

// Minimal reproduction: a client identity set on a relay hop
// (RelayHop tlsOptions -> sec_protocol_options_set_local_identity) is
// presented by URLSession but NOT by WKWebView, given the identical
// ProxyConfiguration. Watch the relay's log: the URLSession button logs
// "peer=[CN=Repro Client]" and loads; the WKWebView button never gets past
// the TLS handshake (Envoy counts ssl.fail_verify_no_cert), and WKWebView
// never offers a client-certificate challenge to its navigation delegate.

let relayEndpoint = NWEndpoint.hostPort(host: "localhost", port: 8443)
let testURL = URL(string: "https://www.apple.com/")!

/// client.p12 (password "repro") is created by server/make-certs.sh.
func clientIdentity() -> SecIdentity? {
    guard let url = Bundle.main.url(forResource: "client", withExtension: "p12"),
          let data = try? Data(contentsOf: url) else { return nil }
    var items: CFArray?
    let options = [kSecImportExportPassphrase as String: "repro"] as CFDictionary
    guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
          let first = (items as? [[String: Any]])?.first,
          let identity = first[kSecImportItemIdentity as String] else { return nil }
    return (identity as! SecIdentity)
}

/// The one ProxyConfiguration both paths use.
func relayWithClientCert() -> ProxyConfiguration {
    let tls = NWProtocolTLS.Options()
    if let identity = clientIdentity(), let secIdentity = sec_identity_create(identity) {
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
    }
    var config = ProxyConfiguration(relayHops: [.init(http2RelayEndpoint: relayEndpoint, tlsOptions: tls)])
    config.allowFailover = false
    return config
}

@main
struct ReproApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @State private var log: [String] = ["identity loaded: \(clientIdentity() != nil)"]
    @State private var webLoads = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("1. Load with URLSession") { Task { await loadWithURLSession() } }
                Button("2. Load with WKWebView") { webLoads += 1 }
            }
            .buttonStyle(.borderedProminent)
            ForEach(Array(log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            ReproWebView(loadCount: webLoads) { log.append($0) }
                .border(.gray)
        }
        .padding()
        .task {
            // `-autorun YES` runs both loads without tapping.
            guard UserDefaults.standard.bool(forKey: "autorun") else { return }
            await loadWithURLSession()
            try? await Task.sleep(for: .seconds(2))
            webLoads += 1
        }
    }

    private func loadWithURLSession() async {
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [relayWithClientCert()]
        do {
            let (_, response) = try await URLSession(configuration: config).data(from: testURL)
            log.append("URLSession: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        } catch {
            log.append("URLSession: \(error.localizedDescription)")
        }
    }
}

struct ReproWebView: UIViewRepresentable {
    let loadCount: Int
    let report: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(report: report) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [relayWithClientCert()]
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard loadCount > context.coordinator.loaded else { return }
        context.coordinator.loaded = loadCount
        webView.load(URLRequest(url: testURL))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = 0
        let report: (String) -> Void
        init(report: @escaping (String) -> Void) { self.report = report }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report("WKWebView: loaded")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let e = error as NSError
            report("WKWebView: failed \(e.domain) \(e.code) \(e.localizedDescription)")
        }

        // Never called for the relay's certificate request.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            report("WKWebView challenge: \(challenge.protectionSpace.authenticationMethod) proxy=\(challenge.protectionSpace.isProxy())")
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
               let identity = clientIdentity() {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
