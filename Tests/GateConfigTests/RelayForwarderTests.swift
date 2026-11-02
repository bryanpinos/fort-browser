import XCTest
import Network
@testable import Fort

final class RelayForwarderParseTests: XCTestCase {

    private func parse(_ head: String) -> Result<RelayForwarder.ConnectRequest, RelayForwarder.ParseError> {
        RelayForwarder.parse(head: head)
    }

    func testConnectWithAuth() {
        let r = parse("CONNECT www.wikipedia.org:443 HTTP/1.1\r\nHost: www.wikipedia.org:443\r\nProxy-Authorization: Basic abc")
        XCTAssertEqual(r, .success(.init(host: "www.wikipedia.org", port: 443, proxyAuthorization: "Basic abc")))
    }

    func testHeaderNameIsCaseInsensitive() {
        let r = parse("CONNECT example.com:80 HTTP/1.1\r\nproxy-authorization:   Basic xyz  ")
        XCTAssertEqual(r, .success(.init(host: "example.com", port: 80, proxyAuthorization: "Basic xyz")))
    }

    func testIPv6Literal() {
        let r = parse("CONNECT [2001:db8::1]:443 HTTP/1.1")
        XCTAssertEqual(r, .success(.init(host: "2001:db8::1", port: 443, proxyAuthorization: nil)))
    }

    func testRejectsOtherMethodsPortsAndGarbage() {
        XCTAssertEqual(parse("GET http://example.com/ HTTP/1.1"), .failure(.notConnect))
        XCTAssertEqual(parse("CONNECT example.com:22 HTTP/1.1"), .failure(.portNotAllowed))
        XCTAssertEqual(parse("CONNECT example.com HTTP/1.1"), .failure(.badTarget))
        XCTAssertEqual(parse("CONNECT :443 HTTP/1.1"), .failure(.badTarget))
        XCTAssertEqual(parse("hello"), .failure(.malformed))
        XCTAssertEqual(parse("CONNECT example.com:443 SPDY/3"), .failure(.malformed))
    }
}

/// Talks to a live forwarder over loopback. The upstream relay is a closed
/// port, so anything that gets past the checks must fail closed with 502.
final class RelayForwarderLoopbackTests: XCTestCase {

    private var forwarder: RelayForwarder!

    override func setUp() async throws {
        forwarder = RelayForwarder()
        let deadRelay = ProxyConfiguration(relayHops: [
            .init(http2RelayEndpoint: .hostPort(host: "127.0.0.1", port: 9)),
        ])
        await MainActor.run { forwarder.start(relay: deadRelay) }
        for _ in 0..<50 where forwarder.port == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNotNil(forwarder.port, "forwarder never started listening")
    }

    override func tearDown() async throws {
        await MainActor.run { forwarder.stop() }
    }

    /// Sends `request` raw and returns the response status line.
    private func statusLine(for request: String) async throws -> String {
        let port = try XCTUnwrap(forwarder.port.flatMap(NWEndpoint.Port.init(rawValue:)))
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { conn.cancel() }
        conn.start(queue: .global())
        conn.send(content: Data(request.utf8), completion: .idempotent)
        let data: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: data ?? Data()) }
            }
        }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
    }

    private var auth: String { RelayForwarder.basicAuth(forwarder.username, forwarder.password) }

    func testMissingCredentialsGet407WithChallenge() async throws {
        let line = try await statusLine(for: "CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(line, "HTTP/1.1 407 Proxy Authentication Required")
    }

    func testWrongCredentialsGet407() async throws {
        let bad = RelayForwarder.basicAuth("fort", "guess")
        let line = try await statusLine(for: "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: \(bad)\r\n\r\n")
        XCTAssertEqual(line, "HTTP/1.1 407 Proxy Authentication Required")
    }

    func testDisallowedPortGets403() async throws {
        let line = try await statusLine(for: "CONNECT example.com:22 HTTP/1.1\r\nProxy-Authorization: \(auth)\r\n\r\n")
        XCTAssertEqual(line, "HTTP/1.1 403 Forbidden")
    }

    func testNonConnectGets405() async throws {
        let line = try await statusLine(for: "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n")
        XCTAssertEqual(line, "HTTP/1.1 405 Method Not Allowed")
    }

    func testOversizedHeaderGets431() async throws {
        let big = String(repeating: "x", count: RelayForwarder.maxHeaderBytes + 100)
        let line = try await statusLine(for: "CONNECT example.com:443 HTTP/1.1\r\nX-Pad: \(big)")
        XCTAssertEqual(line, "HTTP/1.1 431 Request Header Fields Too Large")
    }

    func testUnreachableRelayFailsClosedWith502() async throws {
        let line = try await statusLine(for: "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: \(auth)\r\n\r\n")
        XCTAssertEqual(line, "HTTP/1.1 502 Bad Gateway")
    }

    func testStopClosesThePort() async throws {
        await MainActor.run { forwarder.stop() }
        XCTAssertNil(forwarder.port)
    }
}

/// Needs a local Envoy relay that requires client certs. Skipped unless the
/// runner passes TEST_RUNNER_FORT_P12 (base64 PKCS#12, password "spike")
/// and TEST_RUNNER_FORT_TOKEN.
final class RelayForwarderMTLSIntegrationTests: XCTestCase {

    func testURLSessionThroughForwarderReachesSiteWithClientCert() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let p12 = env["FORT_P12"] else { throw XCTSkip("no spike env") }
        var cfg = GateConfig()
        cfg.proxy = .init(kind: .relay, host: "localhost", port: 8443, authToken: env["FORT_TOKEN"],
                          clientIdentity: .init(pkcs12Base64: p12, password: "spike"))
        let forwarder = RelayForwarder()
        await MainActor.run { forwarder.apply(cfg) }
        defer { forwarder.stop() }
        for _ in 0..<50 where forwarder.port == nil { try await Task.sleep(for: .milliseconds(100)) }
        let port = try XCTUnwrap(forwarder.port.flatMap(NWEndpoint.Port.init(rawValue:)))

        var local = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
        local.applyCredential(username: forwarder.username, password: forwarder.password)
        local.allowFailover = false
        let session = URLSessionConfiguration.ephemeral
        session.proxyConfigurations = [local]
        let (_, response) = try await URLSession(configuration: session).data(from: URL(string: "https://www.wikipedia.org/")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
