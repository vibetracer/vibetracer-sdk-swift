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
        } catch NetworkError.httpStatus(let status, retryable: let retry) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(retry)   // NO kill switch on 401 per design doc
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
        } catch NetworkError.httpStatus(let status, retryable: let retry) {
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
}
