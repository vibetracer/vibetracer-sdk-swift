import XCTest
@testable import VibeTracer

/// Facade-level smoke tests for the `VibeTracer` enum. These exercise the
/// public API shape; the full FSM/mailbox behavior is covered in
/// `VibeTracerCoreTests`.
///
/// We use the internal `configure(apiKey:endpoint:debug:urlSession:)` overload
/// to inject a `URLSession` whose `protocolClasses` list prepends
/// `MockURLProtocol`, avoiding reliance on `URLProtocol.registerClass` (which
/// is not honored by every URLSession configuration path).
final class VibeTracerFacadeTests: XCTestCase {

    private func makeMockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        #if DEBUG
        VibeTracer.resetForTesting()
        #endif
        UserDefaults.standard.removeObject(forKey: "com.vibetracer.disabled")
        try await super.tearDown()
    }

    /// 1 — `configure` + `track` — event reaches the mock network.
    func test_configure_then_track_reachesNetwork() async throws {
        #if DEBUG
        VibeTracer.resetForTesting()
        #endif
        let arrived = expectation(description: "facade_hit POST")
        arrived.assertForOverFulfill = false
        MockURLProtocol.handler = { req in
            if let body = Self.extractBody(req),
               let json = try? JSONSerialization.jsonObject(with: body) {
                let arr: [[String: Any]] = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
                if arr.contains(where: { ($0["event"] as? String) == "facade_hit" }) {
                    arrived.fulfill()
                }
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        VibeTracer.configure(
            apiKey: "vtr_test_facade",
            endpoint: URL(string: "https://api.vibetracer.xyz")!,
            debug: false,
            urlSession: makeMockSession()
        )
        VibeTracer.track("facade_hit", properties: ["k": 1])
        // `track()` spawns a fire-and-forget `Task` to call into the actor;
        // yielding a few times gives that Task a chance to land its signal
        // on the mailbox before `flush()` enqueues `.appBackgrounded`.
        for _ in 0..<20 { await Task.yield() }
        await VibeTracer.flush()
        await fulfillment(of: [arrived], timeout: 5.0)
    }

    /// 2 — `disable()` no-ops subsequent `track()` calls — the named event
    /// never appears in an outbound request body.
    func test_disable_dropsSubsequentTrack() async throws {
        #if DEBUG
        VibeTracer.resetForTesting()
        #endif
        let lock = NSLock()
        nonisolated(unsafe) var bodies: [Data] = []
        MockURLProtocol.handler = { req in
            if let body = Self.extractBody(req) {
                lock.lock(); bodies.append(body); lock.unlock()
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        VibeTracer.configure(
            apiKey: "vtr_test_facade",
            endpoint: URL(string: "https://api.vibetracer.xyz")!,
            debug: false,
            urlSession: makeMockSession()
        )
        VibeTracer.disable()
        // Small pause so the disable signal lands before the track call.
        try await Task.sleep(nanoseconds: 100_000_000)
        VibeTracer.track("should_drop", properties: nil)
        await VibeTracer.flush()
        try await Task.sleep(nanoseconds: 200_000_000)

        lock.lock(); let snapshot = bodies; lock.unlock()
        let saw = snapshot.contains { body in
            guard let json = try? JSONSerialization.jsonObject(with: body) else { return false }
            let arr: [[String: Any]] = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            return arr.contains { ($0["event"] as? String) == "should_drop" }
        }
        XCTAssertFalse(saw, "disabled track() must not reach network")
    }

    /// 3 — `version` is the expected semver.
    func test_version_matchesPublishedRelease() {
        XCTAssertEqual(VibeTracer.version, "2.2.0")
    }

    // MARK: - Helpers

    private static func extractBody(_ r: URLRequest) -> Data? {
        if let d = r.httpBody { return d }
        guard let stream = r.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        var data = Data()
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}
