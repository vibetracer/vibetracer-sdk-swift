import XCTest
import os
@testable import VibeTracer

/// Integration tests for Phase 7.5 — NWPathMonitor-driven early wake from
/// `.backoff`. The production `SystemConnectivityMonitor` is stubbed with a
/// `FakeConnectivityMonitor` so tests can deterministically simulate the
/// offline→online edge without touching the real network stack.
final class ConnectivityIntegrationTests: XCTestCase {

    // MARK: - Harness (mirrors VibeTracerCoreTests.Harness, plus connectivity)

    final class FakeLifecycleObserver: LifecycleObserver {
        var onActivate: () -> Void = {}
        var onBackground: () -> Void = {}
        var onTerminate: () -> Void = {}
        private(set) var started = false
        func start() { started = true }
        func stop() { started = false }
    }

    struct CapturedRequest { let request: URLRequest; let body: Data }
    final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [CapturedRequest] = []
        func record(_ r: URLRequest) {
            let body = Self.extractBody(r) ?? Data()
            lock.lock(); _requests.append(CapturedRequest(request: r, body: body)); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _requests.count }
        func all() -> [CapturedRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
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

    struct Harness {
        let core: VibeTracerCore
        let clock: TestClock
        let disk: DiskQueue
        let lifecycle: FakeLifecycleObserver
        let connectivity: FakeConnectivityMonitor
    }

    private func makeHarness() async -> (Harness, URLSession) {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let diskDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-connectivity-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        let disk = DiskQueue(directory: diskDir)
        let clock = TestClock(start: Date(timeIntervalSinceReferenceDate: 1_000_000))

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let network = Network(
            endpoint: URL(string: "https://api.vibetracer.xyz")!,
            apiKey: "vtr_live_test", sdkVersion: "swift/1.1.0", session: session
        )
        let sessionTracker = SessionTracker(defaults: defaults, clock: clock)
        let userIdStore = UserIdStore(defaults: defaults)
        let lifecycle = FakeLifecycleObserver()
        let connectivity = FakeConnectivityMonitor()
        let logger = Logger(subsystem: "xyz.vibetracer.test", category: "ConnectivityIntegrationTests")

        let core = VibeTracerCore(
            deviceId: UUID(),
            userIdStore: userIdStore,
            sessionTracker: sessionTracker,
            disk: disk,
            network: network,
            clock: clock,
            lifecycle: lifecycle,
            connectivity: connectivity,
            debug: false,
            logger: logger
        )
        return (Harness(core: core, clock: clock, disk: disk, lifecycle: lifecycle, connectivity: connectivity), session)
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
    }

    private func settle(_ core: VibeTracerCore) async {
        await core._waitForIdle()
    }

    private func isBackoff(_ state: QueueState) -> Bool {
        if case .backoff = state { return true }
        return false
    }

    // MARK: - Tests

    /// 1 — Connectivity return while sitting in `.backoff` cancels the
    /// pending timer and dispatches `.backoffExpired` immediately, triggering
    /// a fresh flush attempt BEFORE the TestClock advances past the backoff
    /// ceiling. On the retry we return 202 so the FSM drains back to `.empty`.
    func test_connectivityReturn_earlyWakeCancelsBackoffTimer() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        let attemptsLock = NSLock()
        nonisolated(unsafe) var attempts = 0
        MockURLProtocol.handler = { req in
            recorder.record(req)
            attemptsLock.lock(); attempts += 1; let n = attempts; attemptsLock.unlock()
            // First attempt fails (500 → retryable), second (on early wake) succeeds.
            let code = n == 1 ? 500 : 202
            return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        await h.core.track(event: "a", properties: nil)
        await settle(h.core)

        // First flush — fails, FSM enters `.backoff`.
        h.clock.advance(by: .seconds(5))
        await settle(h.core)
        let stateAfterFail = await h.core._state()
        XCTAssertTrue(isBackoff(stateAfterFail), "expected .backoff after 500; got \(stateAfterFail)")
        let countAfterFail = recorder.count

        // Simulate NWPathMonitor firing: connectivity is back. The early-wake
        // handler should cancel the backoff timer and fire `.backoffExpired`
        // right now — without advancing the TestClock at all.
        h.connectivity.simulateReachable()
        await settle(h.core)

        XCTAssertGreaterThan(recorder.count, countAfterFail, "early wake should have retried the flush")
        let stateAfterRetry = await h.core._state()
        XCTAssertEqual(stateAfterRetry, .empty, "successful retry should drain FSM back to .empty")
        let remaining = try await h.disk.count()
        XCTAssertEqual(remaining, 0)
    }

    /// 2 — Connectivity return while NOT in backoff must be a no-op. We're
    /// sitting idle in `.empty` (everything flushed); a reachability
    /// notification must not enqueue spurious signals nor cause any HTTP call.
    func test_connectivityReturn_whileNotInBackoff_isIgnored() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        // Drain $session_start so we land in `.empty` with a clean slate.
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        let stateBefore = await h.core._state()
        XCTAssertEqual(stateBefore, .empty)
        let countBefore = recorder.count

        // Fire reachable while idle — expected: nothing happens.
        h.connectivity.simulateReachable()
        await settle(h.core)

        XCTAssertEqual(recorder.count, countBefore, "connectivity return in .empty must not trigger HTTP")
        let stateAfter = await h.core._state()
        XCTAssertEqual(stateAfter, .empty)
    }

    /// 3 — `VibeTracerCore.start()` subscribes to connectivity updates by
    /// calling `ConnectivityMonitor.start()`. Without this wiring, early-wake
    /// would never fire in production.
    func test_start_callsConnectivityStart() async throws {
        let (h, _) = await makeHarness()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        XCTAssertFalse(h.connectivity.started)
        await h.core.start()
        await settle(h.core)
        XCTAssertTrue(h.connectivity.started, "VibeTracerCore.start() must call ConnectivityMonitor.start()")
    }
}
