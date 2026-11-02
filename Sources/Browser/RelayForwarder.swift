import Foundation
import Network
import Observation

/// Debug-build-only trace for diagnosing the forwarder on a device
/// (`devicectl device process launch --console`). Compiled out of release.
@inline(__always) func forwarderTrace(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("FORT-FWD \(message())")
    #endif
}

/// Loopback CONNECT proxy that lets WKWebView use a relay requiring mutual TLS.
///
/// WKWebView's own relay support never presents a client certificate: proxy
/// connections are made in WebKit's networking process, which drops the
/// identity. Network-framework connections made in this process do present
/// it. So WebKit is pointed at this proxy on 127.0.0.1, and each CONNECT is
/// re-opened through the relay from here.
///
/// Reported to Apple as FB25401454 (filed 2026-11-02; repro in
/// feedback/relay-client-cert). If a future iOS fixes it, WebKit can use the
/// relay hop directly and this forwarder can go.
///
/// Fail-closed: until this is listening, WebKit's proxy is a dead loopback
/// port; if the relay is unreachable, the CONNECT gets a 502. No direct path.
@Observable
final class RelayForwarder {

    /// Port WebKit should use, or nil when not listening.
    private(set) var port: UInt16?

    /// Per-launch credentials WebKit must present, so other apps on the device
    /// can't borrow the tunnel.
    let username = "fort"
    let password = UUID().uuidString

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var relay: ProxyConfiguration?
    @ObservationIgnored private var context: NWParameters.PrivacyContext?
    @ObservationIgnored private var activeTunnels = 0 // queue-confined

    private let queue = DispatchQueue(label: "dev.pinos.fort.relay-forwarder")
    static let maxTunnels = 128
    static let maxHeaderBytes = 8192
    static let headerTimeout: TimeInterval = 10
    /// How long a CONNECT may wait for the relay before we answer 504, so
    /// WebKit shows an error instead of a page that never loads (e.g. while
    /// iOS holds the connection for the Local Network permission).
    static let upstreamTimeout: TimeInterval = 8
    static let allowedPorts: Set<UInt16> = [80, 443]

    var isRunning: Bool { relay != nil }

    /// Starts (or restarts) forwarding through `relay`.
    func start(relay: ProxyConfiguration) {
        stop()
        self.relay = relay
        let ctx = NWParameters.PrivacyContext(description: "Fort relay")
        ctx.proxyConfigurations = [relay]
        context = ctx
        listen()
    }

    func stop() {
        relay = nil
        context = nil
        let old = listener
        listener = nil
        old?.cancel()
        setPort(nil)
    }

    /// Re-creates the listener if iOS tore it down while we were suspended.
    func ensureListening() {
        guard relay != nil else { return }
        if listener == nil || port == nil { listen() }
    }

    private func setPort(_ value: UInt16?) {
        if Thread.isMainThread { port = value } else { DispatchQueue.main.async { self.port = value } }
    }

    private func listen() {
        let old = listener
        listener = nil
        old?.cancel()
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { setPort(nil); return }
        listener = l
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            // A replaced listener's late callbacks (e.g. .cancelled after a
            // restart) must not touch the port the new listener published.
            guard self.listener === l else { return }
            switch state {
            case .ready:
                forwarderTrace("listening on \(l.port?.rawValue ?? 0)")
                self.setPort(l.port?.rawValue)
            case .failed, .cancelled:
                forwarderTrace("listener \(state)")
                self.setPort(nil)
                if case .failed = state {
                    // Try again shortly with a fresh port; WebKit fails closed meanwhile.
                    self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.listener === l, self.relay != nil else { return }
                        DispatchQueue.main.async { self.listen() }
                    }
                }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
    }

    // MARK: - Tunnels

    private func accept(_ client: NWConnection) {
        guard activeTunnels < Self.maxTunnels, let context else { client.cancel(); return }
        forwarderTrace("accepted connection (\(activeTunnels + 1) active)")
        activeTunnels += 1
        let tunnel = Tunnel(client: client, context: context, queue: queue,
                            expectedAuth: Self.basicAuth(username, password)) { [weak self] in
            self?.activeTunnels -= 1
        }
        tunnel.start()
    }

    static func basicAuth(_ user: String, _ pass: String) -> String {
        "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
    }

    /// Parsed first line + headers of a CONNECT request.
    struct ConnectRequest: Equatable {
        var host: String
        var port: UInt16
        var proxyAuthorization: String?
    }

    enum ParseError: Error, Equatable { case notConnect, badTarget, portNotAllowed, malformed }

    /// Parses an HTTP/1.1 request head (everything before the blank line).
    static func parse(head: String) -> Result<ConnectRequest, ParseError> {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .failure(.malformed) }
        guard parts[0] == "CONNECT" else { return .failure(.notConnect) }
        let authority = String(parts[1])
        guard let colon = authority.lastIndex(of: ":"),
              let port = UInt16(authority[authority.index(after: colon)...]) else { return .failure(.badTarget) }
        var host = String(authority[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, !host.contains(" ") else { return .failure(.badTarget) }
        guard allowedPorts.contains(port) else { return .failure(.portNotAllowed) }
        var auth: String?
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else { continue }
            if line[..<sep].lowercased() == "proxy-authorization" {
                auth = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return .success(ConnectRequest(host: host, port: port, proxyAuthorization: auth))
    }
}

/// One CONNECT: read the request, open the upstream through the relay, splice.
private final class Tunnel {
    private let client: NWConnection
    private var upstream: NWConnection?
    private let context: NWParameters.PrivacyContext
    private let queue: DispatchQueue
    private let expectedAuth: String
    private let onClose: () -> Void
    private var head = Data()
    private var closed = false
    private var established = false

    init(client: NWConnection, context: NWParameters.PrivacyContext, queue: DispatchQueue,
         expectedAuth: String, onClose: @escaping () -> Void) {
        self.client = client
        self.context = context
        self.queue = queue
        self.expectedAuth = expectedAuth
        self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: close()
            default: break
            }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + RelayForwarder.headerTimeout) { [self] in
            if !established && upstream == nil { close() }
        }
        readHead()
    }

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, isComplete, error in
            if let data { head.append(data) }
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                let headText = String(decoding: head[..<end.lowerBound], as: UTF8.self)
                let leftover = head[end.upperBound...]
                handle(headText, leftover: Data(leftover))
            } else if head.count > RelayForwarder.maxHeaderBytes {
                respond("431 Request Header Fields Too Large")
            } else if isComplete || error != nil {
                close()
            } else {
                readHead()
            }
        }
    }

    private func handle(_ headText: String, leftover: Data) {
        let parsed = RelayForwarder.parse(head: headText)
        if case .success(let r) = parsed {
            forwarderTrace("CONNECT \(r.host):\(r.port) auth=\(r.proxyAuthorization == expectedAuth ? "ok" : (r.proxyAuthorization == nil ? "none" : "wrong"))")
        } else {
            forwarderTrace("request rejected: \(parsed)")
        }
        switch parsed {
        case .failure(.notConnect): respond("405 Method Not Allowed")
        case .failure(.portNotAllowed): respond("403 Forbidden")
        case .failure: respond("400 Bad Request")
        case .success(let req):
            guard req.proxyAuthorization == expectedAuth else {
                respond("407 Proxy Authentication Required",
                        extra: "Proxy-Authenticate: Basic realm=\"fort\"\r\n")
                return
            }
            openUpstream(req, leftover: leftover)
        }
    }

    private func openUpstream(_ req: RelayForwarder.ConnectRequest, leftover: Data) {
        let params = NWParameters.tcp
        params.setPrivacyContext(context)
        guard let port = NWEndpoint.Port(rawValue: req.port) else { respond("400 Bad Request"); return }
        let up = NWConnection(host: NWEndpoint.Host(req.host), port: port, using: params)
        upstream = up
        queue.asyncAfter(deadline: .now() + RelayForwarder.upstreamTimeout) { [self] in
            if !established && !closed {
                forwarderTrace("upstream \(req.host):\(req.port) timed out")
                respond("504 Gateway Timeout")
            }
        }
        up.stateUpdateHandler = { [self] state in
            forwarderTrace("upstream \(req.host):\(req.port) -> \(state)")
            switch state {
            case .ready:
                established = true
                client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                            completion: .contentProcessed { [self] error in
                    if error != nil { close(); return }
                    if !leftover.isEmpty {
                        up.send(content: leftover, completion: .contentProcessed { [self] e in if e != nil { close() } })
                    }
                    pump(from: client, to: up)
                    pump(from: up, to: client)
                })
            case .waiting, .failed:
                // .waiting means the relay is unreachable or refused us. Never
                // wait for a better path: fail this CONNECT now.
                if !established { respond("502 Bad Gateway") } else { close() }
            case .cancelled:
                close()
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { [self] e in
                    if e != nil { close() } else if !isComplete && error == nil { pump(from: source, to: sink) }
                })
            } else if !isComplete && error == nil {
                pump(from: source, to: sink)
            }
            if isComplete {
                sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            }
            if error != nil { close() }
        }
    }

    private func respond(_ status: String, extra: String = "") {
        let body = "HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n"
        client.send(content: Data(body.utf8), completion: .contentProcessed { [self] _ in close() })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        upstream?.cancel()
        client.cancel()
        onClose()
    }
}

extension RelayForwarder {
    /// Runs the forwarder only when it's needed: a relay plus a client cert.
    func apply(_ config: GateConfig, identities: ClientIdentityStore) {
        guard let proxy = config.proxy, BrowserView.usesForwarder(proxy, hasIdentity: identities.hasIdentity) else {
            forwarderTrace("not needed for this config"); stop(); return
        }
        // If the keychain item can't be turned into an identity after all,
        // don't listen: WebKit stays on the dead port (fail closed).
        guard let identity = identities.identity() else {
            forwarderTrace("client identity did NOT load; staying closed"); stop(); return
        }
        forwarderTrace("client identity loaded; starting")
        start(relay: BrowserView.proxyConfiguration(for: proxy, identity: identity))
    }
}
