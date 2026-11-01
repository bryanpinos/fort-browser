import Foundation
import Observation

/// Records every top-level navigation decision. Keeps a local ring buffer the
/// parent can view in Settings, and optionally POSTs batches to `logEndpoint`.
@Observable
final class ActivityLogger {

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var timestamp: Date
        var url: String
        var allowed: Bool
        var reason: String?
    }

    /// Parent-assigned name for this device; see `ConfigStore.deviceName`.
    var deviceName: String = ""

    private(set) var entries: [Entry] = []
    private let maxLocalEntries = 500

    private var pending: [Entry] = []
    private var endpoint: URL?
    private var flushTask: Task<Void, Never>?

    init(endpoint: URL?) {
        self.endpoint = endpoint
        startFlushLoop()
    }

    func apply(endpoint: URL?) {
        self.endpoint = endpoint
    }

    func record(url: URL, allowed: Bool, reason: String? = nil) {
        let entry = Entry(timestamp: Date(), url: url.absoluteString, allowed: allowed, reason: reason)
        entries.insert(entry, at: 0)
        if entries.count > maxLocalEntries { entries.removeLast(entries.count - maxLocalEntries) }
        if endpoint != nil { pending.append(entry) }
    }

    func clearLocal() {
        entries.removeAll()
    }

    private func startFlushLoop() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.flush()
            }
        }
    }

    @MainActor
    func flush() async {
        guard let endpoint, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try? encoder.encode(Batch(device: reportedDeviceName, entries: batch))
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                pending.insert(contentsOf: batch, at: 0)
            }
        } catch {
            pending.insert(contentsOf: batch, at: 0) // retry next cycle
        }
    }

    /// The parent-assigned name, or model plus a stable per-install suffix.
    /// `UIDevice.name` isn't used: since iOS 16 it returns just "iPad" without a
    /// special entitlement, so two iPads would be indistinguishable.
    @MainActor
    var reportedDeviceName: String {
        if !deviceName.isEmpty { return deviceName }
        #if canImport(UIKit)
        let suffix = UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "unknown"
        return "\(UIDevice.current.model)-\(suffix)"
        #else
        return "unknown"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif

private struct Batch: Encodable {
    var device: String
    var entries: [ActivityLogger.Entry]
}
