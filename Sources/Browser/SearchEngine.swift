import Foundation

/// Where address-bar searches go (`GateConfig.searchEngine`). The three built-in
/// engines get strict safe search forced by `SafeSearch`; a custom engine
/// doesn't, because Fort can't know how that site turns it on.
enum SearchEngine: Equatable, Hashable {
    case google, bing, duckDuckGo
    /// An https address with `%s` where the query goes,
    /// e.g. `https://search.example.com/search?q=%s`.
    case custom(String)

    static let builtIn: [SearchEngine] = [.google, .bing, .duckDuckGo]

    /// Reads the config value. Missing, unknown or invalid values mean Google,
    /// so a typo in a pushed config never breaks searching.
    init(setting: String?) {
        let value = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "bing": self = .bing
        case "duckduckgo": self = .duckDuckGo
        default:
            self = Self.isValidCustom(value) ? .custom(value) : .google
        }
    }

    /// The config value; nil for Google, the default.
    var setting: String? {
        switch self {
        case .google: return nil
        case .bing: return "bing"
        case .duckDuckGo: return "duckduckgo"
        case .custom(let template): return template
        }
    }

    var name: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        case .custom(let template): return URL(string: template.replacingOccurrences(of: "%s", with: ""))?.host ?? "Custom"
        }
    }

    /// Only the built-in engines can have strict safe search forced.
    var supportsSafeSearch: Bool {
        if case .custom = self { return false }
        return true
    }

    /// True for a value `init(setting:)` accepts: a built-in name or a custom template.
    static func isValidSetting(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        return ["google", "bing", "duckduckgo"].contains(value.lowercased()) || isValidCustom(value)
    }

    /// An https address with `%s` for the query and a host.
    static func isValidCustom(_ template: String) -> Bool {
        guard template.lowercased().hasPrefix("https://"), template.contains("%s"),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: "q")) else { return false }
        return !(url.host ?? "").isEmpty
    }

    func searchURL(for query: String) -> URL? {
        let template: String
        switch self {
        case .google: template = "https://www.google.com/search?q=%s"
        case .bing: template = "https://www.bing.com/search?q=%s"
        case .duckDuckGo: template = "https://duckduckgo.com/?q=%s"
        case .custom(let custom): template = custom
        }
        // Encode everything but unreserved characters, so the query can't add
        // parameters or change the path of the template.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}
