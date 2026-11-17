import XCTest
@testable import Fort

final class ClientIdentityStoreTests: XCTestCase {

    /// A per-test keychain service, so tests never touch the app's real item.
    private var store: ClientIdentityStore!
    private var service: String!

    override func setUp() {
        service = "dev.pinos.fort.tests.\(UUID().uuidString)"
        store = ClientIdentityStore(service: service)
    }

    override func tearDown() {
        store.remove()
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-ipad", withExtension: "p12"))
        return try Data(contentsOf: url)
    }

    func testStartsEmpty() {
        XCTAssertNil(store.info)
        XCTAssertFalse(store.hasIdentity)
        XCTAssertNil(store.identity())
    }

    func testImportReadsNameDeviceIDAndExpiry() throws {
        let info = try store.importPKCS12(try fixture(), password: "fixture")
        XCTAssertEqual(info.name, "Fixture iPad")
        XCTAssertEqual(info.deviceID, "fixture-ipad")
        if #available(iOS 18.0, *) {
            XCTAssertGreaterThan(try XCTUnwrap(info.expires), Date())
        }
        XCTAssertTrue(store.hasIdentity)
        XCTAssertNotNil(store.identity())
    }

    func testImportPersistsAcrossInstances() throws {
        try store.importPKCS12(try fixture(), password: "fixture")
        let reopened = ClientIdentityStore(service: service)
        XCTAssertEqual(reopened.info?.deviceID, "fixture-ipad")
        XCTAssertNotNil(reopened.identity())
    }

    func testWrongPasswordIsRejectedAndNothingStored() throws {
        XCTAssertThrowsError(try store.importPKCS12(try fixture(), password: "nope")) { error in
            XCTAssertEqual(error as? ClientIdentityStore.ImportError, .wrongPassword)
        }
        XCTAssertNil(store.info)
        XCTAssertNil(ClientIdentityStore(service: service).info)
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try store.importPKCS12(Data("not a p12".utf8), password: "x")) { error in
            guard case .unreadable = error as? ClientIdentityStore.ImportError else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
        XCTAssertNil(store.info)
    }

    func testFailedReplacementKeepsTheExistingCertificate() throws {
        try store.importPKCS12(try fixture(), password: "fixture")
        XCTAssertThrowsError(try store.importPKCS12(try fixture(), password: "wrong"))
        XCTAssertEqual(store.info?.deviceID, "fixture-ipad")
        XCTAssertNotNil(ClientIdentityStore(service: service).identity())
    }

    func testRemoveClearsKeychainItem() throws {
        try store.importPKCS12(try fixture(), password: "fixture")
        store.remove()
        XCTAssertNil(store.info)
        XCTAssertNil(ClientIdentityStore(service: service).info)
    }

    func testDeviceIDParsing() {
        // GeneralName [6] URI, followed by the next field's SEQUENCE tag (0x30 = "0").
        func der(_ s: String) -> Data { Data([0x30, 0x82, 0x86, UInt8(s.utf8.count)] + Array(s.utf8) + [0x30, 0x0b]) }
        XCTAssertEqual(ClientIdentityStore.deviceID(inCertificateDER: der("spiffe://example.com/fort/device/kid1-ipad")), "kid1-ipad")
        XCTAssertEqual(ClientIdentityStore.deviceID(inCertificateDER: der("spiffe://home.example.net/fort/device/Ava.iPad_2")), "Ava.iPad_2",
                       "any family's trust domain works")
        XCTAssertNil(ClientIdentityStore.deviceID(inCertificateDER: der("spiffe://example.com/other/device/x")))
        XCTAssertNil(ClientIdentityStore.deviceID(inCertificateDER: der("spiffe://example.com/fort/device/")))
        XCTAssertNil(ClientIdentityStore.deviceID(inCertificateDER: der("spiffe://example.com/fort/device/a/b")))
        XCTAssertNil(ClientIdentityStore.deviceID(inCertificateDER: der("spiffe:///fort/device/x")), "needs a trust domain")
    }
}
