import XCTest
import WebKit
@testable import Fort

/// Captures request bodies and headers for relay ingest uploads.
private final class IngestStub: URLProtocol {
    static var requests: [(headers: [String: String], body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "relay.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        Self.requests.append((request.allHTTPHeaderFields ?? [:], body))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class PageReviewUploadTests: XCTestCase {

    private func makeLogger(reviewPages: Bool) -> ActivityLogger {
        IngestStub.requests = []
        let logger = ActivityLogger(endpoint: nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IngestStub.self]
        logger.uploadConfiguration = config
        logger.apply(ingest: .init(url: URL(string: "https://relay.test:8443/fort/ingest")!, token: "tok"),
                     reviewPages: reviewPages)
        return logger
    }

    private func uploadedEvents() throws -> [[String: Any]] {
        let body = try XCTUnwrap(IngestStub.requests.last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["events"] as? [[String: Any]])
    }

    func testNavigationsGoToRelayWithToken() async throws {
        let logger = makeLogger(reviewPages: false)
        logger.record(url: URL(string: "https://www.wikipedia.org/")!, allowed: true)
        logger.record(url: URL(string: "https://bad.example/")!, allowed: false, reason: "blocked host")
        await logger.flush()
        XCTAssertEqual(IngestStub.requests.last?.headers["x-fort-token"], "tok")
        let events = try uploadedEvents()
        XCTAssertEqual(events.map { $0["kind"] as? String }, ["nav", "nav"])
        XCTAssertEqual(events.last?["allowed"] as? Bool, false)
        XCTAssertEqual(events.last?["reason"] as? String, "blocked host")
        XCTAssertTrue(logger.pending.isEmpty)
    }

    func testPageTextOnlyWhenReviewIsOn() async throws {
        let off = makeLogger(reviewPages: false)
        XCTAssertFalse(off.wantsPageText)
        off.recordPage(url: URL(string: "https://a.example/")!, title: "A", text: "hello")
        XCTAssertTrue(off.pending.isEmpty)

        let on = makeLogger(reviewPages: true)
        XCTAssertTrue(on.wantsPageText)
        on.recordPage(url: URL(string: "https://a.example/")!, title: "A", text: String(repeating: "x", count: 5000))
        await on.flush()
        let page = try XCTUnwrap(try uploadedEvents().first)
        XCTAssertEqual(page["kind"] as? String, "page")
        XCTAssertEqual(page["title"] as? String, "A")
        XCTAssertEqual((page["text"] as? String)?.count, 2000, "text is capped at 2,000 characters")
    }

    func testNoRelayMeansNoPageText() {
        let logger = ActivityLogger(endpoint: URL(string: "http://logs.example/log"))
        logger.apply(ingest: nil, reviewPages: true)
        XCTAssertFalse(logger.wantsPageText, "page text only ever goes to the relay")
    }

    func testPendingQueueIsBounded() {
        let logger = makeLogger(reviewPages: false)
        for i in 0..<(ActivityLogger.maxPending + 50) {
            logger.record(url: URL(string: "https://e.example/\(i)")!, allowed: true)
        }
        XCTAssertEqual(logger.pending.count, ActivityLogger.maxPending)
        XCTAssertEqual(logger.pending.last?.url, "https://e.example/\(ActivityLogger.maxPending + 49)", "newest kept")
    }
}

@MainActor
final class PageTextScriptTests: XCTestCase {

    func testExtractsTitleAndCollapsedVisibleText() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let loaded = expectation(description: "loaded")
        final class Done: NSObject, WKNavigationDelegate {
            let e: XCTestExpectation
            init(_ e: XCTestExpectation) { self.e = e }
            func webView(_ w: WKWebView, didFinish n: WKNavigation!) { e.fulfill() }
        }
        let delegate = Done(loaded)
        webView.navigationDelegate = delegate
        webView.loadHTMLString("""
            <html><head><title>Cats   Page</title></head><body>
            <h1>All   about
            cats</h1><script>var secret = "not visible text";</script>
            <p style="display:none">hidden paragraph</p><p>Purr.</p></body></html>
            """, baseURL: URL(string: "https://cats.example/"))
        await fulfillment(of: [loaded], timeout: 10)
        let viaHandler: Any? = await withCheckedContinuation { c in
            webView.evaluateJavaScript(BrowserView.Coordinator.pageTextScript, in: nil, in: .defaultClient) { r in
                c.resume(returning: try? r.get())
            }
        }
        // Same completion-handler call the app makes. (The async overload of
        // evaluateJavaScript returned () for object results on iOS 27.2.)
        let result = viaHandler
        let page = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(page["title"] as? String, "Cats Page", "document.title is whitespace-normalized")
        let text = try XCTUnwrap(page["text"] as? String)
        XCTAssertTrue(text.contains("All about cats"), text)
        XCTAssertTrue(text.contains("Purr."), text)
        XCTAssertFalse(text.contains("secret"), "script source isn't visible text")
        XCTAssertFalse(text.contains("hidden paragraph"), "hidden elements aren't visible text")
    }
}
