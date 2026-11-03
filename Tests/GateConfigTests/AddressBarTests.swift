import XCTest
@testable import Fort

final class AddressBarTests: XCTestCase {

    private func isSearch(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let url = BrowserModel.destination(for: text)
        XCTAssertEqual(url?.host, "www.google.com", "\(text) should be a search", file: file, line: line)
        XCTAssertEqual(url?.path, "/search", file: file, line: line)
        let q = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value }
        XCTAssertEqual(q, text.trimmingCharacters(in: .whitespaces), file: file, line: line)
    }

    private func isAddress(_ text: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(BrowserModel.destination(for: text)?.absoluteString, expected, file: file, line: line)
    }

    func testPlainWordsAndQuestionsAreSearches() {
        isSearch("cats")
        isSearch("minecraft")
        isSearch("how tall is a giraffe")
        isSearch("what is 2.5 + 3")
    }

    func testDottedThingsThatAreNotDomainsAreSearches() {
        isSearch("minecraft.exe")
        isSearch("2.5")
        isSearch("v1.2.3")
        isSearch("hello.notarealtld")
        isSearch("about:blank")
        isSearch("word:thing")
    }

    func testRealAddressesOpenDirectly() {
        isAddress("pbskids.org", "https://pbskids.org")
        isAddress("en.wikipedia.org/wiki/Cat", "https://en.wikipedia.org/wiki/Cat")
        isAddress("bbc.co.uk", "https://bbc.co.uk")
        isAddress("coolmath.games", "https://coolmath.games")
        isAddress("example.com:8080/x", "https://example.com:8080/x")
        isAddress("1.1.1.1", "https://1.1.1.1")
        isAddress("https://www.nasa.gov/", "https://www.nasa.gov/")
        isAddress("http://example.com", "http://example.com")
        isAddress("  NatGeoKids.COM  ", "https://NatGeoKids.COM")
    }

    func testOtherSchemesAreNeverOpenedFromTheAddressBar() {
        isSearch("javascript:alert(1)")
        isSearch("file:///etc/passwd")
    }

    func testEmptyInputDoesNothing() {
        XCTAssertNil(BrowserModel.destination(for: "   "))
    }
}
