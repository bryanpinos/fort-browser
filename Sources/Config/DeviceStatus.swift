import UIKit

/// What this iPad reports home with each home-config fetch, for the parents'
/// console: whether Fort is the default browser, and which build is running.
enum DeviceStatus {
    private static let defaultBrowserKey = "fort.isDefaultBrowser"

    /// Asks iOS whether Fort is the default browser (iPadOS 18.2+) and keeps the
    /// answer. iOS rate-limits this question, so on an error the last answer stands.
    static func refreshDefaultBrowser() {
        guard #available(iOS 18.2, *), let answer = try? UIApplication.shared.isDefault(.webBrowser) else { return }
        UserDefaults.standard.set(answer ? "yes" : "no", forKey: defaultBrowserKey)
    }

    /// The last known answer: "yes", "no" or "unknown".
    static var defaultBrowser: String {
        UserDefaults.standard.string(forKey: defaultBrowserKey) ?? "unknown"
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Headers added to the home-config request.
    static func headers(defaultBrowser: String = DeviceStatus.defaultBrowser,
                        appVersion: String = DeviceStatus.appVersion) -> [String: String] {
        ["x-fort-default-browser": defaultBrowser, "x-fort-app-version": appVersion]
    }
}
