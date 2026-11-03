import Foundation
import Observation
import Security

/// Records every top-level navigation decision. Keeps a local ring buffer the
/// parent can view in Settings, and uploads batches every 30 s:
/// - relay configured: to the relay's `/fort/ingest` with this device's client
///   certificate and the token (works away from home); the relay stamps the
///   device ID from the certificate. With `reviewPages`, page text goes too.
/// - otherwise: to `logEndpoint`, if set (legacy JSON batch).
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

    /// Where to upload when a relay is configured.
    struct Ingest: Equatable {
        var url: URL
        var token: String?
    }

    /// One queued upload item (navigation decision or page content).
    struct Event: Codable, Equatable {
        enum Kind: String, Codable { case nav, page }
        var kind: Kind
        var ts: Date
        var url: String
        var allowed: Bool = true
        var reason: String? = nil
        var title: String? = nil
        var text: String? = nil
    }

    static let maxPending = 1000

    private(set) var pending: [Event] = []
    private var endpoint: URL?
    private var flushTask: Task<Void, Never>?
    @ObservationIgnored private(set) var ingest: Ingest?
    @ObservationIgnored private(set) var reviewPages = false
    /// Supplies the client identity for relay uploads (read at upload time).
    @ObservationIgnored var identityProvider: () -> SecIdentity? = { nil }
    /// Session configuration for relay uploads (tests inject protocol stubs).
    @ObservationIgnored var uploadConfiguration: URLSessionConfiguration = .ephemeral

    /// Whether page text should be captured right now.
    var wantsPageText: Bool { ingest != nil && reviewPages }

    init(endpoint: URL?) {
        self.endpoint = endpoint
        startFlushLoop()
    }

    func apply(endpoint: URL?) {
        self.endpoint = endpoint
    }

    /// Relay upload target (nil = no relay) and whether page text is wanted.
    func apply(ingest: Ingest?, reviewPages: Bool) {
        self.ingest = ingest
        self.reviewPages = reviewPages
    }

    func record(url: URL, allowed: Bool, reason: String? = nil) {
        let entry = Entry(timestamp: Date(), url: url.absoluteString, allowed: allowed, reason: reason)
        entries.insert(entry, at: 0)
        if entries.count > maxLocalEntries { entries.removeLast(entries.count - maxLocalEntries) }
        if ingest != nil || endpoint != nil {
            enqueue(Event(kind: .nav, ts: entry.timestamp, url: entry.url, allowed: allowed, reason: reason))
        }
    }

    /// Page content for parental review; ignored unless review is on.
    func recordPage(url: URL, title: String, text: String) {
        guard wantsPageText else { return }
        enqueue(Event(kind: .page, ts: Date(), url: url.absoluteString,
                      title: String(title.prefix(300)), text: String(text.prefix(2000))))
    }

    private func enqueue(_ event: Event) {
        pending.append(event)
        // Bounded: if home is unreachable for a long time, drop the oldest.
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
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
        guard !pending.isEmpty, ingest != nil || endpoint != nil else { return }
        let batch = Array(pending.prefix(200))
        pending.removeFirst(batch.count)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let request: URLRequest
        let session: URLSession
        if let ingest {
            var r = URLRequest(url: ingest.url)
            r.httpBody = try? encoder.encode(["events": batch])
            if let token = ingest.token { r.setValue(token, forHTTPHeaderField: "x-fort-token") }
            request = r
            let delegate = ClientCertificateDelegate(identity: identityProvider())
            session = URLSession(configuration: uploadConfiguration, delegate: delegate, delegateQueue: nil)
        } else if let endpoint {
            let entries = batch.filter { $0.kind == .nav }.map {
                Entry(timestamp: $0.ts, url: $0.url, allowed: $0.allowed, reason: $0.reason)
            }
            var r = URLRequest(url: endpoint)
            r.httpBody = try? encoder.encode(Batch(device: reportedDeviceName, entries: entries))
            request = r
            session = URLSession.shared
        } else {
            return
        }
        var post = request
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        defer { if session !== URLSession.shared { session.finishTasksAndInvalidate() } }
        do {
            let (_, response) = try await session.data(for: post)
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
