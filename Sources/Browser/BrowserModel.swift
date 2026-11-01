import Foundation
import Observation
import WebKit

/// UI-facing state for the browser chrome. The WKWebView itself lives in
/// `BrowserView`'s coordinator; this object is what SwiftUI binds to.
@Observable
final class BrowserModel {
    var urlText: String = ""
    var currentURL: URL?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var blockedMessage: String?

    /// Set by the coordinator; weak so the view owns the WebView.
    weak var webView: WKWebView?

    func load(text: String, homeURL: URL) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url: URL
        if let direct = URL(string: trimmed), direct.scheme != nil, direct.host != nil {
            url = direct
        } else if trimmed.contains(".") && !trimmed.contains(" "),
                  let guessed = URL(string: "https://" + trimmed) {
            url = guessed
        } else {
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            url = c.url ?? homeURL
        }
        load(url: url)
    }

    func load(url: URL) {
        blockedMessage = nil
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }
}
