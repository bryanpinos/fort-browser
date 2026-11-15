import Foundation
import CryptoKit
import Observation

/// Loads and persists `GateConfig`. Precedence:
///   1. Managed app configuration pushed by an MDM (AppConfig), key "config" (JSON string)
///   2. Home config from the relay (`/fort/config`): each field it contains replaces
///      the local value; its `proxy` is ignored (that's this iPad's own connection)
///   3. Locally saved config (UserDefaults)
///   4. Defaults
@Observable
final class ConfigStore {
    private(set) var config: GateConfig
    private(set) var isManaged: Bool
    /// Fields the home config controls; Parent settings shows them as managed.
    private(set) var managedFromHome: Set<String> = []

    /// What Parent settings saves; the home config is layered on top of it.
    @ObservationIgnored private var local: GateConfig
    @ObservationIgnored private var home: [String: Any]?

    /// Per-device label sent with activity logs (e.g. "Ava's iPad"). Kept out of
    /// `GateConfig` so importing one shared fort.json on every iPad doesn't
    /// overwrite it, and it isn't exported. Empty means "not set".
    private(set) var deviceName: String

    private static let localKey = "fort.config.json"
    private static let homeKey = "fort.homeConfig.json"
    /// Fields only this iPad decides, whatever the home config says.
    static let localOnlyKeys: Set<String> = ["proxy"]
    private static let managedKey = "com.apple.configuration.managed"
    private static let deviceNameKey = "fort.deviceName"

    init() {
        deviceName = UserDefaults.standard.string(forKey: ConfigStore.deviceNameKey) ?? ""
        local = ConfigStore.loadLocal() ?? .default
        if let managed = ConfigStore.loadManaged() {
            config = managed
            isManaged = true
        } else {
            config = local
            isManaged = false
            if let data = UserDefaults.standard.data(forKey: ConfigStore.homeKey),
               let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let merged = ConfigStore.merge(local, saved) {
                home = saved
                config = merged
                managedFromHome = Set(saved.keys)
            }
        }
    }

    func update(_ newConfig: GateConfig) {
        guard !isManaged else { config = newConfig; return }
        local = newConfig
        if let data = try? JSONEncoder.pretty.encode(newConfig) {
            UserDefaults.standard.set(data, forKey: ConfigStore.localKey)
        }
        config = home.flatMap { ConfigStore.merge(newConfig, $0) } ?? newConfig
    }

    /// Applies a home config fetched from the relay. Returns false, changing
    /// nothing, if it isn't a JSON object or wouldn't make a valid config: the
    /// iPad keeps its last good settings.
    @discardableResult
    func applyHome(_ data: Data) -> Bool {
        guard !isManaged,
              var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        for key in ConfigStore.localOnlyKeys { fields.removeValue(forKey: key) }
        guard let merged = ConfigStore.merge(local, fields),
              let clean = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return false }
        UserDefaults.standard.set(clean, forKey: ConfigStore.homeKey)
        home = fields
        managedFromHome = Set(fields.keys)
        if merged != config { config = merged }
        return true
    }

    /// `base` with each field in `fields` replacing its value, or nil if the
    /// result isn't a valid config.
    static func merge(_ base: GateConfig, _ fields: [String: Any]) -> GateConfig? {
        guard let baseData = try? JSONEncoder().encode(base),
              var object = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any] else { return nil }
        for (key, value) in fields where !localOnlyKeys.contains(key) { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let merged = try? JSONDecoder().decode(GateConfig.self, from: data),
              isWebAddress(merged.homeURL),
              (merged.favorites ?? []).allSatisfy({ isWebAddress($0.url) }) else { return nil }
        return merged
    }

    /// iOS turns almost any text into some URL, so check it's a real web address.
    private static func isWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// Import from a pasted JSON string. Throws on malformed input.
    func importJSON(_ text: String) throws {
        let data = Data(text.utf8)
        let cfg = try JSONDecoder().decode(GateConfig.self, from: data)
        update(cfg)
    }

    /// Fetch config JSON from a URL (handy for first-run setup: parent hosts
    /// fort.json on the NAS and types the URL once).
    func importFrom(url: URL) async throws {
        let (data, _) = try await URLSession.shared.data(from: url)
        let cfg = try JSONDecoder().decode(GateConfig.self, from: data)
        update(cfg)
    }

    func exportJSON() -> String {
        guard let data = try? JSONEncoder.pretty.encode(config) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func set(deviceName name: String) {
        deviceName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(deviceName, forKey: ConfigStore.deviceNameKey)
    }

    // MARK: PIN

    static func hash(pin: String) -> String {
        let digest = SHA256.hash(data: Data(pin.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func verify(pin: String) -> Bool {
        guard let stored = config.parentPINHash else { return true }
        return ConfigStore.hash(pin: pin) == stored
    }

    func set(pin: String?) {
        var cfg = config
        cfg.parentPINHash = pin.flatMap { $0.isEmpty ? nil : ConfigStore.hash(pin: $0) }
        update(cfg)
    }

    // MARK: Loading

    private static func loadManaged() -> GateConfig? {
        guard let dict = UserDefaults.standard.dictionary(forKey: managedKey),
              let json = dict["config"] as? String else { return nil }
        return try? JSONDecoder().decode(GateConfig.self, from: Data(json.utf8))
    }

    private static func loadLocal() -> GateConfig? {
        guard let data = UserDefaults.standard.data(forKey: localKey) else { return nil }
        return try? JSONDecoder().decode(GateConfig.self, from: data)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
