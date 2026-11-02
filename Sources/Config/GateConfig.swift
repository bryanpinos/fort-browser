import Foundation

/// Everything a parent configures. Serialised as JSON so it can be pasted,
/// fetched from a URL, scanned from a QR code, or pushed by an MDM via
/// managed app configuration (`com.apple.configuration.managed` → "config").
struct GateConfig: Codable, Equatable {

    /// A URL that only answers 2xx when the device is on the parent's network
    /// (e.g. a tiny nginx on the NAS at its Tailscale address). If nil, the
    /// gate is open and the app behaves like a plain filtered browser.
    var probeURL: URL?

    /// How often to re-check the probe while the app is in the foreground.
    var probeIntervalSeconds: Double = 15

    /// Optional proxy that ALL WebView traffic is pinned through. Combined with
    /// a tailnet-only proxy address, this makes the gate implicit: no tunnel,
    /// no proxy, no page.
    var proxy: ProxyConfig?

    /// If non-empty, only these hosts (and their subdomains) may load.
    var allowlist: [String] = []

    /// Hosts (and subdomains) that may never load. Applied even with an allowlist.
    var denylist: [String] = []

    /// Rewrite search-engine URLs to force strict safe search.
    var enforceSafeSearch: Bool = true

    /// Page shown on launch and when the Home button is tapped.
    var homeURL: URL = URL(string: "https://www.wikipedia.org")!

    /// Optional endpoint that receives batched activity logs as JSON POSTs.
    /// Logs stay on-device if this is nil.
    var logEndpoint: URL?

    /// SHA-256 (hex) of the parent PIN. Nil means settings are unprotected.
    var parentPINHash: String?

    struct ProxyConfig: Codable, Equatable {
        /// `relay` is an Apple network relay (CONNECT over TLS + HTTP/2):
        /// encrypted and authenticated, so it can sit on the open internet.
        enum Kind: String, Codable { case socks5, http, relay }
        var kind: Kind
        var host: String
        var port: UInt16
        /// Sent as `x-fort-token` on every relay request. Relay only.
        /// The relay's client certificate is NOT part of the config: it's
        /// imported once per device into the keychain (ClientIdentityStore).
        var authToken: String? = nil
    }

    static let `default` = GateConfig()
}

extension GateConfig {
    /// Host matching helper shared by allow/deny checks: exact or subdomain.
    static func host(_ host: String, matchesAnyOf patterns: [String]) -> Bool {
        let h = host.lowercased()
        for p in patterns {
            let pat = p.lowercased().trimmingCharacters(in: .whitespaces)
            guard !pat.isEmpty else { continue }
            if h == pat || h.hasSuffix("." + pat) { return true }
        }
        return false
    }

    func allows(host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true } // about:blank, data:, etc.
        if GateConfig.host(host, matchesAnyOf: denylist) { return false }
        if !allowlist.isEmpty, !GateConfig.host(host, matchesAnyOf: allowlist) { return false }
        return true
    }
}
