import XCTest
import UIKit
@testable import Fort

final class DeviceNameStoreTests: XCTestCase {

    private let keys = ["fort.deviceName", "fort.config.json"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in keys {
            UserDefaults.standard.set(saved[k], forKey: k)
        }
    }

    func testDefaultsToEmpty() {
        XCTAssertEqual(ConfigStore().deviceName, "")
    }

    func testIsTrimmedAndPersistsAcrossLaunches() {
        ConfigStore().set(deviceName: "  Ava's iPad \n")
        XCTAssertEqual(ConfigStore().deviceName, "Ava's iPad")
    }

    func testImportingASharedConfigKeepsTheName() throws {
        let store = ConfigStore()
        store.set(deviceName: "Ava's iPad")
        try store.importJSON("""
        {"probeIntervalSeconds":15,"allowlist":[],"denylist":["tiktok.com"],
         "enforceSafeSearch":true,"homeURL":"https://www.wikipedia.org"}
        """)
        XCTAssertEqual(store.config.denylist, ["tiktok.com"])
        XCTAssertEqual(store.deviceName, "Ava's iPad")
    }

    func testNameIsNotExported() {
        let store = ConfigStore()
        store.set(deviceName: "Ava's iPad")
        XCTAssertFalse(store.exportJSON().contains("Ava"))
    }
}

/// Captures requests made through URLSession.shared.
private final class CapturingProtocol: URLProtocol {
    static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "logs.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            Self.bodies.append(data)
        } else if let body = request.httpBody {
            Self.bodies.append(body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ActivityLoggerDeviceTests: XCTestCase {

    override func setUp() {
        CapturingProtocol.bodies = []
        URLProtocol.registerClass(CapturingProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(CapturingProtocol.self)
    }

    private func flushedDevice(name: String) async throws -> String? {
        let logger = ActivityLogger(endpoint: URL(string: "http://logs.test/log"))
        logger.deviceName = name
        logger.record(url: URL(string: "https://www.wikipedia.org/")!, allowed: true)
        await logger.flush()
        let body = try XCTUnwrap(CapturingProtocol.bodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["entries"] as? [Any])?.count, 1)
        return json["device"] as? String
    }

    func testBatchCarriesParentAssignedName() async throws {
        let device = try await flushedDevice(name: "Ava's iPad")
        XCTAssertEqual(device, "Ava's iPad")
    }

    func testUnnamedDeviceGetsModelPlusStableSuffix() async throws {
        let device = try await flushedDevice(name: "")
        let expected = "\(UIDevice.current.model)-" + (UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "unknown")
        XCTAssertEqual(device, expected)
        XCTAssertNotEqual(device, UIDevice.current.model, "bare model name can't tell two iPads apart")
    }
}
