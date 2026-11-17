import Foundation
import Observation
import WebKit

/// One browser tab: UI-facing state plus the WKWebView and its delegate.
/// Tabs own their web view (rather than the SwiftUI view owning it) so that
/// switching tabs never reloads a page. Created and managed by `TabsModel`.
@Observable
final class BrowserModel: Identifiable {
    let id = UUID()
    var urlText: String = ""
    var currentURL: URL?
    var title: String = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    /// Small banner for ordinary failures ("couldn't reach home", etc.).
    var blockedMessage: String?
    /// Set when Fort blocked a page; the tab then shows the block page.
    var block: Block?

    struct Block: Equatable {
        enum Reason: Equatable {
            case notAllowed      // Fort's allow/deny lists
            case blockedAtHome   // the home content filter (relay sinkhole)
            case download        // Fort doesn't download files
        }
        var reason: Reason
        var host: String
    }
    /// True while the tab shows Fort's favorites start page instead of a site.
    var showsStartPage = false

    /// The tab's web view and delegate (set by `TabsModel`).
    @ObservationIgnored var webView: WKWebView?
    @ObservationIgnored var coordinator: BrowserView.TabCoordinator?

    /// Tab strip label.
    var displayTitle: String {
        if showsStartPage { return "New Tab" }
        if block != nil && (currentURL == nil || currentURL?.scheme == "about") { return "Blocked" }
        if !title.isEmpty { return title }
        return currentURL?.host ?? "Loading…"
    }

    func load(text: String, engine: SearchEngine) {
        guard let url = Self.destination(for: text, engine: engine) else { return }
        load(url: url)
    }

    /// What the address bar should open for `text`: an address if it clearly
    /// is one, otherwise a search on `engine` (SafeSearch forces strict mode
    /// on the built-in engines).
    /// "Clearly an address" = an http(s) URL, an IPv4 address, or a dotted
    /// host name ending in a real top-level domain ("minecraft.exe" and
    /// "2.5" are searches, "pbskids.org/games" is an address).
    static func destination(for text: String, engine: SearchEngine = .google) -> URL? {
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
        return engine.searchURL(for: input)
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
        block = nil
        showsStartPage = false
        webView?.load(URLRequest(url: url))
    }

    /// Show the favorites start page in this tab.
    func showStartPage() {
        blockedMessage = nil
        block = nil
        webView?.stopLoading()
        showsStartPage = true
        urlText = ""
    }

    func goBack() {
        if block != nil { block = nil; return }  // the blocked page never loaded
        webView?.goBack()
    }

    /// Leave the block page: back to the page the kid was on, or the start
    /// page if this tab had nothing else.
    func dismissBlock() {
        block = nil
        if webView?.url == nil || webView?.url?.scheme == "about" { showStartPage() }
    }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }
}
