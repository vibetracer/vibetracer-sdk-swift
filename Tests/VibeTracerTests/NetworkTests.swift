import XCTest
@testable import VibeTracer

final class NetworkTests: XCTestCase {
    var session: URLSession!

    override func setUp() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: cfg)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
    }

    func test_post_200_ok() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/v1/events")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer vtr_live_abc")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Vibetracer-SDK"), "swift/1.1.0")
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        let net = Network(endpoint: URL(string: "https://api.vibetracer.xyz")!,
                          apiKey: "vtr_live_abc", sdkVersion: "swift/1.1.0", session: session)
        let batch = [AnalyticsEvent(event: "x", deviceId: "d", userId: nil, sessionId: "s")]
        try await net.post(batch)   // should not throw
    }

    func test_post_401_retryable() async {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let net = Network(endpoint: URL(string: "https://api.vibetracer.xyz")!,
                          apiKey: "vtr_live_abc", sdkVersion: "swift/1.1.0", session: session)
        do {
            try await net.post([AnalyticsEvent(event: "x", deviceId: "d", userId: nil, sessionId: "s")])
            XCTFail("expected throw")
        } catch NetworkError.httpStatus(let status, retryable: let retry, retryAfter: let ra) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(retry)   // NO kill switch on 401 per design doc
            XCTAssertNil(ra)       // no Retry-After header was set
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_post_400_permanent() async {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }
        let net = Network(endpoint: URL(string: "https://api.vibetracer.xyz")!,
                          apiKey: "k", sdkVersion: "swift/1.1.0", session: session)
        do {
            try await net.post([AnalyticsEvent(event: "x", deviceId: "d", userId: nil, sessionId: "s")])
            XCTFail("expected throw")
        } catch NetworkError.httpStatus(let status, retryable: let retry, retryAfter: _) {
            XCTAssertEqual(status, 400)
            XCTAssertFalse(retry)   // 400/422 are permanent
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_post_offline_retryable() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let net = Network(endpoint: URL(string: "https://api.vibetracer.xyz")!,
                          apiKey: "k", sdkVersion: "swift/1.1.0", session: session)
        do {
            try await net.post([AnalyticsEvent(event: "x", deviceId: "d", userId: nil, sessionId: "s")])
            XCTFail("expected throw")
        } catch NetworkError.transport {
            // success — transport errors are retryable
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: - Retry-After parsing

    func test_post_429_with_retryAfter_header_parsesSeconds() async {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil,
                             headerFields: ["Retry-After": "7"])!, Data())
        }
        let net = Network(endpoint: URL(string: "https://api.vibetracer.xyz")!,
                          apiKey: "k", sdkVersion: "swift/1.1.0", session: session)
        do {
            try await net.post([AnalyticsEvent(event: "x", deviceId: "d", userId: nil, sessionId: "s")])
            XCTFail("expected throw")
        } catch NetworkError.httpStatus(let status, retryable: let retry, retryAfter: let ra) {
            XCTAssertEqual(status, 429)
            XCTAssertTrue(retry)
            XCTAssertEqual(ra, .seconds(7))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_post_503_with_retryAfter_cappedAtMax() async {
        // Header asks us to wait an hour; we cap at Network.maxRetryAfter (300s)
        // to avoid indefinite starvation from a misbehaving upstream.
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil,
                             headerFields: ["Retry-After": "3600"])!, Data())
        }
        let net = Network(endpoint: URL(string: "https://api.vibetracer.xyz")!,
                          apiKey: "k", sdkVersion: "swift/1.1.0", session: session)
        do {
            try await net.post([AnalyticsEvent(event: "x", deviceId: "d", userId: nil, sessionId: "s")])
            XCTFail("expected throw")
        } catch NetworkError.httpStatus(_, retryable: _, retryAfter: let ra) {
            XCTAssertEqual(ra, Network.maxRetryAfter)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_post_429_ignoresUnparseableRetryAfter() async {
        // HTTP-date form — RFC-valid but we don't implement it; must return
        // nil rather than throw, so the FSM falls back to the exp-backoff
        // ladder.
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil,
                             headerFields: ["Retry-After": "Fri, 31 Dec 1999 23:59:59 GMT"])!, Data())
        }
        let net = Network(endpoint: URL(string: "https://api.vibetracer.xyz")!,
                          apiKey: "k", sdkVersion: "swift/1.1.0", session: session)
        do {
            try await net.post([AnalyticsEvent(event: "x", deviceId: "d", userId: nil, sessionId: "s")])
            XCTFail("expected throw")
        } catch NetworkError.httpStatus(_, retryable: _, retryAfter: let ra) {
            XCTAssertNil(ra)
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: - parseRetryAfter edge cases (pure)

    func test_parseRetryAfter_validForms() {
        XCTAssertEqual(parseRetryAfter("1"), .seconds(1))
        XCTAssertEqual(parseRetryAfter("  42 "), .seconds(42))
        XCTAssertEqual(parseRetryAfter("300"), .seconds(300))
    }

    func test_parseRetryAfter_rejectsNonPositiveAndGarbage() {
        XCTAssertNil(parseRetryAfter(nil))
        XCTAssertNil(parseRetryAfter(""))
        XCTAssertNil(parseRetryAfter("0"))     // zero = "retry immediately" — ignored to avoid hammering
        XCTAssertNil(parseRetryAfter("-5"))
        XCTAssertNil(parseRetryAfter("1.5"))   // non-integer
        XCTAssertNil(parseRetryAfter("soon"))
    }

    func test_parseRetryAfter_capsAtMax() {
        XCTAssertEqual(parseRetryAfter("301"), Network.maxRetryAfter)
        XCTAssertEqual(parseRetryAfter("99999"), Network.maxRetryAfter)
    }
}
