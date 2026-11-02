import Foundation
import Network
import Observation
import Security

/// Decides whether browsing is allowed right now. Fail-closed: any error
/// counts as disconnected.
///
/// - Relay configured: probes the relay itself (`/fort/health`) with this
///   device's client certificate and the token, so "connected" means the
///   relay is reachable AND accepts this iPad. No third-party request.
/// - Otherwise, if `probeURL` is set: GETs it directly; only 2xx = connected.
/// - Neither: the gate is open (plain filtered browser).
@Observable
final class NetworkGate {

    enum State: Equatable {
        case open                // nothing to check; gate disabled
        case checking            // first check in flight
        case connected
        case disconnected(reason: String)
        case needsLocalNetwork   // iOS is blocking Fort from reaching home
    }

    private(set) var state: State = .checking
    private(set) var lastChecked: Date?

    private var task: Task<Void, Never>?
    private var config: GateConfig
    @ObservationIgnored private let identities: ClientIdentityStore?

    init(config: GateConfig, identities: ClientIdentityStore? = nil) {
        self.config = config
        self.identities = identities
    }

    var isAllowed: Bool {
        switch state {
        case .open, .connected: return true
        default: return false
        }
    }

    /// True when the gate checks the relay (the overlay hides VPN advice).
    var usesRelay: Bool { config.proxy?.kind == .relay }

    func apply(config: GateConfig) {
        self.config = config
        restart()
    }

    func start() { restart() }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Manual re-check, e.g. after "Check again".
    func checkNow() {
        Task { await probeOnce() }
    }

    private func restart() {
        stop()
        guard usesRelay || config.probeURL != nil else {
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
        if let proxy = config.proxy, proxy.kind == .relay {
            await probeRelay(proxy)
        } else if let url = config.probeURL {
            await probeURL(url)
        } else {
            state = .open
        }
    }

    // MARK: - Direct probe URL

    private static let directSession: URLSession = URLSession(configuration: probeConfiguration())

    private static func probeConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 6
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return c
    }

    @MainActor
    private func probeURL(_ url: URL) async {
        var request = URLRequest(url: url)
        request.setValue("Fort/1 probe", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await Self.directSession.data(for: request)
            lastChecked = Date()
            state = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
                ? .connected : .disconnected(reason: "Probe returned an unexpected status")
        } catch {
            lastChecked = Date()
            state = .disconnected(reason: "Home network not reachable")
        }
    }

    // MARK: - Relay health probe

    static func relayHealthURL(for proxy: GateConfig.ProxyConfig) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = proxy.host
        c.port = Int(proxy.port)
        c.path = "/fort/health"
        return c.url
    }

    @MainActor
    private func probeRelay(_ proxy: GateConfig.ProxyConfig) async {
        guard let url = Self.relayHealthURL(for: proxy) else {
            state = .disconnected(reason: "The relay address isn't valid"); return
        }
        var request = URLRequest(url: url)
        request.setValue("Fort/1 probe", forHTTPHeaderField: "User-Agent")
        if let token = proxy.authToken { request.setValue(token, forHTTPHeaderField: "x-fort-token") }
        let delegate = ClientCertificateDelegate(identity: identities?.identity())
        let session = URLSession(configuration: Self.probeConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            lastChecked = Date()
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: state = .connected
            case 404: state = .disconnected(reason: "Home isn't accepting this iPad (check the relay token)")
            default: state = .disconnected(reason: "Home answered unexpectedly")
            }
        } catch {
            lastChecked = Date()
            if await Self.isLocalNetworkDenied(host: proxy.host, port: proxy.port) {
                state = .needsLocalNetwork
            } else if identities?.hasIdentity == false {
                state = .disconnected(reason: "This iPad has no certificate for home yet")
            } else {
                state = .disconnected(reason: "Can't reach home right now")
            }
        }
    }

    /// Asks Network framework whether iOS is blocking local-network access to
    /// `host`. Only a definite "denied" counts; anything else (timeouts, a
    /// pending prompt, an unrelated failure) returns false.
    static func isLocalNetworkDenied(host: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func finish(_ value: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    finish(false)
                case .waiting:
                    finish(connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(false) }
        }
    }
}

/// Answers the relay's client-certificate request with this device's identity
/// and leaves server trust to the system.
final class ClientCertificateDelegate: NSObject, URLSessionTaskDelegate {
    private let identity: SecIdentity?

    init(identity: SecIdentity?) { self.identity = identity }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate, let identity {
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .none))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
