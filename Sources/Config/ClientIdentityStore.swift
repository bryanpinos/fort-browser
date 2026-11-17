import Foundation
import Observation
import Security

/// The relay client certificate (mutual TLS), kept in the keychain.
///
/// Deliberately not part of `GateConfig`: the config is shared, exported and
/// fetched from URLs, while the certificate is this device's secret. Stored as
/// the PKCS#12 bytes plus its password in one generic-password item that is
/// `ThisDeviceOnly` (never in backups or iCloud Keychain), and re-imported with
/// `SecPKCS12Import` when needed.
@Observable
final class ClientIdentityStore {

    struct Info: Equatable {
        var name: String          // certificate subject summary, e.g. "Ava's iPad"
        var deviceID: String?     // from the spiffe://<trust domain>/fort/device/<id> URI SAN
        var expires: Date?
    }

    enum ImportError: LocalizedError, Equatable {
        case wrongPassword
        case unreadable(OSStatus)
        case noIdentity
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .wrongPassword: return "That password doesn't open this certificate."
            case .unreadable(let s): return "This file isn't a certificate Fort can read (error \(s)). If it was made with `step`, re-export it with --legacy."
            case .noIdentity: return "The file has no certificate with a private key."
            case .keychain(let s): return "Couldn't save to the keychain (error \(s))."
            }
        }
    }

    /// What's installed, or nil. Observed by the UI and the forwarder.
    private(set) var info: Info?

    private let service: String
    private static let account = "relay-client"

    init(service: String = "dev.pinos.fort.relay-client") {
        self.service = service
        info = load().flatMap { Self.info(for: $0.identity) }
    }

    var hasIdentity: Bool { info != nil }

    /// Validates the PKCS#12, then replaces any stored identity with it.
    @discardableResult
    func importPKCS12(_ data: Data, password: String) throws -> Info {
        let identity = try Self.identity(from: data, password: password)
        let blob = try JSONEncoder().encode(Stored(pkcs12: data, password: password))
        removeItem()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: blob,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw ImportError.keychain(status) }
        let newInfo = Self.info(for: identity) ?? Info(name: "Certificate", deviceID: nil, expires: nil)
        info = newInfo
        return newInfo
    }

    func remove() {
        removeItem()
        info = nil
    }

    /// The identity to present to the relay, or nil if none is stored.
    func identity() -> SecIdentity? { load()?.identity }

    // MARK: - Keychain

    private struct Stored: Codable { var pkcs12: Data; var password: String }

    private func load() -> (stored: Stored, identity: SecIdentity)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let identity = try? Self.identity(from: stored.pkcs12, password: stored.password) else { return nil }
        return (stored, identity)
    }

    private func removeItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - PKCS#12 and certificate details

    static func identity(from data: Data, password: String) throws -> SecIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        switch status {
        case errSecSuccess: break
        case errSecAuthFailed: throw ImportError.wrongPassword
        default: throw ImportError.unreadable(status)
        }
        guard let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw ImportError.noIdentity }
        return (identity as! SecIdentity)
    }

    static func info(for identity: SecIdentity) -> Info? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        let name = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Certificate"
        let der = SecCertificateCopyData(certificate) as Data
        var expires: Date?
        if #available(iOS 18.0, *) {
            expires = SecCertificateCopyNotValidAfterDate(certificate) as Date?
        }
        return Info(name: name, deviceID: deviceID(inCertificateDER: der), expires: expires)
    }

    /// iOS has no public API for reading SANs, so find the Fort device URI in
    /// the DER. A URI SAN is encoded as tag 0x86, a length, then the ASCII
    /// bytes; use that length rather than guessing where the URI ends (the
    /// next field's tag byte can look like an ID character).
    static func deviceID(inCertificateDER der: Data) -> String? {
        let scheme = Array("spiffe://".utf8)
        let bytes = [UInt8](der)
        guard bytes.count > scheme.count + 2 else { return nil }
        for start in 2...(bytes.count - scheme.count) where bytes[start..<start + scheme.count].elementsEqual(scheme) {
            let length: Int
            if bytes[start - 2] == 0x86 && bytes[start - 1] < 0x80 {
                length = Int(bytes[start - 1])                       // short form
            } else if start >= 3 && bytes[start - 3] == 0x86 && bytes[start - 2] == 0x81 {
                length = Int(bytes[start - 1])                       // long form, 1 length byte
            } else {
                continue
            }
            let end = start + length
            guard end <= bytes.count else { continue }
            if let id = deviceID(inURI: String(decoding: bytes[start..<end], as: UTF8.self)) { return id }
        }
        return nil
    }

    /// `spiffe://<trust domain>/fort/device/<id>`, for any trust domain (each
    /// family uses its own); nil for anything else.
    static func deviceID(inURI uri: String) -> String? {
        let rest = uri.dropFirst("spiffe://".count)
        guard uri.hasPrefix("spiffe://"), let marker = rest.range(of: "/fort/device/") else { return nil }
        let domain = rest[..<marker.lowerBound], id = rest[marker.upperBound...]
        guard !domain.isEmpty, domain.utf8.allSatisfy({ isIDByte($0) && $0 != UInt8(ascii: "_") }),
              !id.isEmpty, id.utf8.count <= 64, id.utf8.allSatisfy(isIDByte) else { return nil }
        return String(id)
    }

    private static func isIDByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F || b == 0x2E
    }
}
