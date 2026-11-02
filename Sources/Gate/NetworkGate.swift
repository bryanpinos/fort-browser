import Foundation
import Observation

/// Periodically probes a parent-controlled URL. The browser is usable only
/// while the probe succeeds. Fail-closed: any error counts as disconnected.
@Observable
final class NetworkGate {

    enum State: Equatable {
        case open          // no probe configured; gate disabled
        case checking      // first check in flight
        case connected
        case disconnected(reason: String)
    }

    private(set) var state: State = .checking
    private(set) var lastChecked: Date?

    private var task: Task<Void, Never>?
    private var config: GateConfig

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 6
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }()

    init(config: GateConfig) {
        self.config = config
    }

    var isAllowed: Bool {
        switch state {
        case .open, .connected: return true
        default: return false
        }
    }

    func apply(config: GateConfig) {
        self.config = config
        restart()
    }

    func start() { restart() }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Manual re-check, e.g. after the kid taps "I turned Tailscale on".
    func checkNow() {
        Task { await probeOnce() }
    }

    private func restart() {
        stop()
        guard config.probeURL != nil else {
            state = .open
            return
        }
        state = .checking
        let interval = max(5, config.probeIntervalSeconds)
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    @MainActor
    private func probeOnce() async {
        guard let url = config.probeURL else { state = .open; return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Fort/1 probe", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            lastChecked = Date()
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                state = .connected
            } else {
                state = .disconnected(reason: "Probe returned an unexpected status")
            }
        } catch {
            lastChecked = Date()
            state = .disconnected(reason: "Home network not reachable")
        }
    }
}
