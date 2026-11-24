import Foundation

/// Links from a page to another app (`roblox://…`). Fort opens one only if the
/// parent listed its scheme in `GateConfig.appLinks`, never for the schemes
/// below, and only after the kid confirms, so a page can't launch apps on its own.
enum AppLinks {

    enum Decision: Equatable {
        /// Ordinary web navigation: Fort's normal checks apply.
        case web
        /// Not a link to an app (data:, blob:, javascript:, file:…): refuse quietly.
        case refuse
        /// A link to an app the parent allowed: ask, then hand it to iOS.
        case ask(app: String)
        /// A link to an app that isn't allowed: refuse, and say so.
        case notAllowed(app: String)
    }

    /// Schemes Fort loads itself.
    private static let webSchemes: Set<String> = ["http", "https", "about"]

    /// Schemes that aren't other apps: never handed off, no banner.
    private static let internalSchemes: Set<String> = ["data", "blob", "javascript", "file", "ws", "wss", "webkit", "x-apple-data-detectors"]

    /// Never handed off, even if listed: other browsers (a way around Fort),
    /// Shortcuts (runs arbitrary actions), Settings and app installs.
    static let neverAllowed: Set<String> = [
        // Browsers
        "x-safari-http", "x-safari-https", "com-apple-mobilesafari-tab", "x-web-search",
        "googlechrome", "googlechromes", "googlechrome-x-callback", "firefox", "firefox-focus", "fennec",
        "microsoft-edge", "microsoft-edge-http", "microsoft-edge-https", "opera-http", "opera-https",
        "brave", "ddgquicklink", "duckduckgo", "onionhttp", "onionhttps", "orion", "arc", "ecosia", "kagi",
        // Automation, settings and installs
        "shortcuts", "workflow", "prefs", "app-prefs", "app-settings",
        "itms", "itms-apps", "itms-appss", "itms-services", "itms-beta", "macappstore",
    ]

    /// A config entry as a scheme: lowercased, "://" and ":" dropped. Nil if it
    /// isn't a valid URL scheme, or is a web or internal one.
    static func normalize(_ entry: String) -> String? {
        var s = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix("://") { s.removeLast(3) } else if s.hasSuffix(":") { s.removeLast() }
        guard s.range(of: "^[a-z][a-z0-9+.-]{0,63}$", options: .regularExpression) != nil,
              !webSchemes.contains(s), !internalSchemes.contains(s) else { return nil }
        return s
    }

    static func decision(for url: URL, allowed: [String]?) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .refuse }
        if webSchemes.contains(scheme) { return .web }
        if internalSchemes.contains(scheme) || normalize(scheme) == nil { return .refuse }
        let list = Set((allowed ?? []).compactMap(normalize))
        let app = displayName(for: scheme)
        if list.contains(scheme), !neverAllowed.contains(scheme) { return .ask(app: app) }
        return .notAllowed(app: app)
    }

    /// "roblox" → "Roblox". iOS doesn't say which app owns a scheme.
    static func displayName(for scheme: String) -> String {
        scheme.prefix(1).uppercased() + scheme.dropFirst()
    }
}
