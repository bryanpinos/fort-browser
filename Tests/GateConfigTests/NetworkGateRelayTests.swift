import XCTest
@testable import Fort

final class NetworkGateRelayTests: XCTestCase {

    private func relayConfig(host: String, port: UInt16 = 8443, token: String? = "t") -> GateConfig {
        var c = GateConfig()
        c.proxy = .init(kind: .relay, host: host, port: port, authToken: token)
        return c
    }

    private func waitForSettled(_ gate: NetworkGate, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if gate.state != .checking { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("gate never left .checking")
    }

    func testHealthURL() {
        let url = NetworkGate.relayHealthURL(for: .init(kind: .relay, host: "relay.example.com", port: 8443))
        XCTAssertEqual(url?.absoluteString, "https://relay.example.com:8443/fort/health")
    }

    func testRelayModeIsNotOpenWithoutAProbeURL() {
        let gate = NetworkGate(config: relayConfig(host: "relay.example.com"))
        gate.start()
        defer { gate.stop() }
        XCTAssertTrue(gate.usesRelay)
        XCTAssertNotEqual(gate.state, .open, "relay mode must check home, not open the gate")
        XCTAssertFalse(gate.isAllowed)
    }

    @MainActor
    func testUnreachableRelayFailsClosed() async throws {
        let gate = NetworkGate(config: relayConfig(host: "10.255.255.1"),
                               identities: ClientIdentityStore(service: "dev.pinos.fort.tests.\(UUID().uuidString)"))
        gate.start()
        defer { gate.stop() }
        try await waitForSettled(gate)
        guard case .disconnected = gate.state else { return XCTFail("expected disconnected, got \(gate.state)") }
        XCTAssertFalse(gate.isAllowed)
    }

    /// Needs the real relay. Skipped unless TEST_RUNNER_FORT_P12 (+ _PASSWORD),
    /// TEST_RUNNER_FORT_TOKEN and TEST_RUNNER_FORT_RELAY_HOST are set.
    @MainActor
    func testRealRelayWithCertificateIsConnected() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let p12 = env["FORT_P12"], let host = env["FORT_RELAY_HOST"] else { throw XCTSkip("no relay env") }
        let identities = ClientIdentityStore(service: "dev.pinos.fort.tests.\(UUID().uuidString)")
        defer { identities.remove() }
        try identities.importPKCS12(try XCTUnwrap(Data(base64Encoded: p12)), password: env["FORT_P12_PASSWORD"] ?? "spike")
        let gate = NetworkGate(config: relayConfig(host: host, token: env["FORT_TOKEN"]), identities: identities)
        gate.start()
        defer { gate.stop() }
        try await waitForSettled(gate)
        XCTAssertEqual(gate.state, .connected)
    }

    func testBlockedCheckAsksTheRelayAboutTheHost() {
        let proxy = GateConfig.ProxyConfig(kind: .relay, host: "relay.example.com", port: 8443, authToken: "t")
        XCTAssertEqual(NetworkGate.relayBlockedURL(for: proxy, host: "www.example.com")?.absoluteString,
                       "https://relay.example.com:8443/fort/blocked?host=www.example.com")
    }

    func testBlockedCheckWithoutARelayIsNo() async {
        let gate = NetworkGate(config: GateConfig())
        let blocked = await gate.isBlockedAtHome(host: "www.example.com")
        XCTAssertFalse(blocked)
    }
}
