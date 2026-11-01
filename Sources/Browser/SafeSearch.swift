import Foundation

/// Rewrites search-engine URLs so strict safe search is always on.
/// Kids can't turn it off because the browser re-applies it on every navigation.
enum SafeSearch {

    static func enforced(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        var changed = false

        func set(_ name: String, _ value: String) {
            if let i = items.firstIndex(where: { $0.name == name }) {
                if items[i].value != value { items[i].value = value; changed = true }
            } else {
                items.append(URLQueryItem(name: name, value: value)); changed = true
            }
        }

        switch true {
        case host.hasSuffix("google.com") || host.contains(".google."):
            if components.path.hasPrefix("/search") { set("safe", "active") }
        case host.hasSuffix("bing.com"):
            if components.path.hasPrefix("/search") || components.path.hasPrefix("/images") { set("adlt", "strict") }
        case host.hasSuffix("duckduckgo.com"):
            set("kp", "1")
        case host.hasSuffix("youtube.com"):
            // YouTube restricted mode is cookie/header based; handled via the
            // YouTube-Restrict header at the proxy or via DNS (restrict.youtube.com).
            break
        default:
            break
        }

        guard changed else { return nil }
        components.queryItems = items
        return components.url
    }
}
