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
        guard let url = Self.destination(for: text) else { return }
        load(url: url)
    }

    /// What the address bar should open for `text`: an address if it clearly
    /// is one, otherwise a Google search (SafeSearch forces strict mode).
    /// "Clearly an address" = an http(s) URL, an IPv4 address, or a dotted
    /// host name ending in a real top-level domain ("minecraft.exe" and
    /// "2.5" are searches, "pbskids.org/games" is an address).
    static func destination(for text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let url = URL(string: input), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil {
            return url
        }
        if input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, looksLikeAddress(input),
           let url = URL(string: "https://" + input), url.host != nil {
            return url
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: input)]
        return search.url
    }

    static func looksLikeAddress(_ input: String) -> Bool {
        let hostAndPort = input.split(maxSplits: 1, whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? input
        let parts = hostAndPort.split(separator: ":", omittingEmptySubsequences: false)
        guard let hostPart = parts.first, parts.count <= 2 else { return false }
        if parts.count == 2, Int(parts[1]) == nil { return false }  // "word:thing" isn't host:port
        let host = hostPart.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }  // IPv4
        guard labels.count >= 2, labels.allSatisfy(isHostLabel), let tld = labels.last else { return false }
        return (tld.count == 2 && tld.allSatisfy(\.isLetter)) || commonTLDs.contains(String(tld))
    }

    private static func isHostLabel(_ label: Substring) -> Bool {
        !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
            && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Generic TLDs a kid is likely to type; any two-letter country code also counts.
    static let commonTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "io", "app", "dev", "ai",
        "tv", "me", "co", "us", "uk", "news", "blog", "shop", "store", "online", "site", "xyz",
        "tech", "games", "game", "fun", "kids", "art", "music", "live", "world", "page", "wiki",
        "school", "academy", "club", "today", "zone", "space", "website", "cloud", "museum",
    ]

    func load(url: URL) {
        blockedMessage = nil
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }
}
