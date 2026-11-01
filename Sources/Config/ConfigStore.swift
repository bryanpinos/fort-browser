import Foundation
import CryptoKit
import Observation

/// Loads and persists `GateConfig`. Precedence:
///   1. Managed app configuration pushed by an MDM (AppConfig), key "config" (JSON string)
///   2. Locally saved config (UserDefaults)
///   3. Defaults
@Observable
final class ConfigStore {
    private(set) var config: GateConfig
    private(set) var isManaged: Bool

    private static let localKey = "hearth.config.json"
    private static let managedKey = "com.apple.configuration.managed"

    init() {
        if let managed = ConfigStore.loadManaged() {
            config = managed
            isManaged = true
        } else if let local = ConfigStore.loadLocal() {
            config = local
            isManaged = false
        } else {
            config = .default
            isManaged = false
        }
    }

    func update(_ newConfig: GateConfig) {
        config = newConfig
        guard !isManaged else { return }
        if let data = try? JSONEncoder.pretty.encode(newConfig) {
            UserDefaults.standard.set(data, forKey: ConfigStore.localKey)
        }
    }

    /// Import from a pasted JSON string. Throws on malformed input.
    func importJSON(_ text: String) throws {
        let data = Data(text.utf8)
        let cfg = try JSONDecoder().decode(GateConfig.self, from: data)
        update(cfg)
    }

    /// Fetch config JSON from a URL (handy for first-run setup: parent hosts
    /// hearth.json on the NAS and types the URL once).
    func importFrom(url: URL) async throws {
        let (data, _) = try await URLSession.shared.data(from: url)
        let cfg = try JSONDecoder().decode(GateConfig.self, from: data)
        update(cfg)
    }

    func exportJSON() -> String {
        guard let data = try? JSONEncoder.pretty.encode(config) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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
