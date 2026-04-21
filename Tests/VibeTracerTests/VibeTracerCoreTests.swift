import XCTest
import os
@testable import VibeTracer

/// Integration-style tests for `VibeTracerCore`. Each test uses a temp dir for
/// disk, a fresh UserDefaults suite for identity, `TestClock` for time, and
/// `MockURLProtocol` for network.
final class VibeTracerCoreTests: XCTestCase {

    // MARK: - Helpers

    /// Bag of references a test needs to drive the actor and inspect results.
    struct Harness {
        let core: VibeTracerCore
        let clock: TestClock
        let disk: DiskQueue
        let lifecycle: FakeLifecycleObserver
        let sessionTracker: SessionTracker
        let userIdStore: UserIdStore
        let defaults: UserDefaults
        let diskDir: URL
        let suiteName: String
    }

    final class FakeLifecycleObserver: LifecycleObserver {
        var onActivate: () -> Void = {}
        var onBackground: () -> Void = {}
        var onTerminate: () -> Void = {}
        private(set) var started = false
        func start() { started = true }
        func stop() { started = false }
    }

    /// Tracks every request (with its body) seen by `MockURLProtocol` across a
    /// test. URLSession rewrites `URLRequest.httpBody` into `httpBodyStream`
    /// before handing the request to a URLProtocol, so we extract the body
    /// eagerly from whichever slot holds it.
    struct CapturedRequest { let request: URLRequest; let body: Data }
    final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [CapturedRequest] = []
        func record(_ r: URLRequest) {
            let body = Self.extractBody(r) ?? Data()
            lock.lock(); _requests.append(CapturedRequest(request: r, body: body)); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _requests.count }
        func last() -> CapturedRequest? { lock.lock(); defer { lock.unlock() }; return _requests.last }
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

    private func makeHarness(
        debug: Bool = false,
        batchLimit: Int = 20,
        idleTimeout: Duration = .seconds(30 * 60),
        initiallyDisabled: Bool = false,
        prePopulatedDisk: [AnalyticsEvent] = [],
        initialSessionInDefaults: (id: UUID, lastActivity: Date)? = nil,
        deviceContext: DeviceContext = .current()
    ) async -> (Harness, URLSession) {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!

        if let initial = initialSessionInDefaults {
            defaults.set(initial.id.uuidString, forKey: "com.vibetracer.sessionId")
            defaults.set(initial.lastActivity.timeIntervalSinceReferenceDate, forKey: "com.vibetracer.sessionLastActivityAt")
        }

        let diskDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-core-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        let disk = DiskQueue(directory: diskDir)
        if !prePopulatedDisk.isEmpty {
            try? await disk.persist(prePopulatedDisk)
        }

        let clock = TestClock(start: Date(timeIntervalSinceReferenceDate: 1_000_000))

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: cfg)

        let network = Network(
            endpoint: URL(string: "https://api.vibetracer.xyz")!,
            apiKey: "vtr_live_test", sdkVersion: "swift/1.1.0", session: session
        )
        let sessionTracker = SessionTracker(defaults: defaults, clock: clock, idleTimeout: idleTimeout)
        let userIdStore = UserIdStore(defaults: defaults)
        let lifecycle = FakeLifecycleObserver()
        let logger = Logger(subsystem: "xyz.vibetracer.test", category: "VibeTracerCoreTests")

        let core = VibeTracerCore(
            deviceId: UUID(),
            userIdStore: userIdStore,
            sessionTracker: sessionTracker,
            disk: disk,
            network: network,
            clock: clock,
            lifecycle: lifecycle,
            debug: debug,
            logger: logger,
            batchLimit: batchLimit,
            initiallyDisabled: initiallyDisabled,
            deviceContext: deviceContext
        )

        let harness = Harness(
            core: core, clock: clock, disk: disk, lifecycle: lifecycle,
            sessionTracker: sessionTracker, userIdStore: userIdStore,
            defaults: defaults, diskDir: diskDir, suiteName: suiteName
        )
        return (harness, session)
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
    }

    /// Drain any test work that might have enqueued lifecycle-driven signals.
    private func settle(_ core: VibeTracerCore) async {
        await core._waitForIdle()
    }

    /// Parse a POST body into the list of event names (supports single-object
    /// or array forms per `Network.post`'s on-the-wire contract).
    private func eventNames(in body: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: body) else { return [] }
        if let arr = json as? [[String: Any]] { return arr.compactMap { $0["event"] as? String } }
        if let obj = json as? [String: Any] { return [obj["event"] as? String].compactMap { $0 } }
        return []
    }

    // MARK: - Tests

    /// 1 — Single track: persists to disk, flushes after timer fires.
    func test_track_persistsToDisk_flushesAfterTimer() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        await h.core.track(event: "a", properties: nil)
        await settle(h.core)
        let countAfterTrack = try await h.disk.count()
        // Disk holds session_start + "a" (session_end absent — fresh session).
        XCTAssertGreaterThanOrEqual(countAfterTrack, 2)

        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        XCTAssertEqual(recorder.count, 1)
        let names = recorder.last().map { eventNames(in: $0.body) } ?? []
        XCTAssertTrue(names.contains("a"))
        let remaining = try await h.disk.count()
        XCTAssertEqual(remaining, 0)
    }

    /// 2 — Batch-size trigger flushes at `batchLimit` events without waiting on the timer.
    func test_batchSize_trigger_flushesAtLimit() async throws {
        let (h, _) = await makeHarness(batchLimit: 5)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        // start() already enqueued $session_start. Tracking 4 more hits the limit of 5.
        for i in 0..<4 {
            await h.core.track(event: "e\(i)", properties: nil)
        }
        await settle(h.core)

        XCTAssertGreaterThanOrEqual(recorder.count, 1, "batchFull should have flushed without timer")
        // All events consumed.
        let remaining = try await h.disk.count()
        XCTAssertEqual(remaining, 0)
    }

    /// 3 — Offline → online transition: retries with backoff until success.
    func test_offline_thenOnline_retriesUntilSuccess() async throws {
        let (h, _) = await makeHarness()
        let attemptCount = NSLock()
        nonisolated(unsafe) var attempts = 0
        MockURLProtocol.handler = { req in
            attemptCount.lock(); attempts += 1; let n = attempts; attemptCount.unlock()
            if n < 4 { throw URLError(.notConnectedToInternet) }
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        await h.core.track(event: "x", properties: nil)
        await settle(h.core)
        h.clock.advance(by: .seconds(5)) // first flush — fails (1)
        await settle(h.core)
        // Now in backoff; advance enough to fire each backoff (1s..8s + jitter).
        for _ in 0..<6 {
            h.clock.advance(by: .seconds(60))
            await settle(h.core)
        }
        XCTAssertGreaterThanOrEqual(attempts, 4)
    }

    /// 4 — 400 permanent drop: batch removed, warning logged, subsequent track works.
    func test_permanent400_dropsBatch_andSubsequentTrackSucceeds() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        nonisolated(unsafe) var status: Int = 400
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        await h.core.track(event: "bad", properties: nil)
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        let firstCount = recorder.count
        XCTAssertGreaterThanOrEqual(firstCount, 1)
        // Disk cleared (permanent drop)
        let remaining = try await h.disk.count()
        XCTAssertEqual(remaining, 0)

        // Second track should enqueue and flush — queue is unblocked.
        status = 202
        await h.core.track(event: "good", properties: nil)
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)
        XCTAssertGreaterThan(recorder.count, firstCount)
    }

    /// 5 — 401 (no kill switch): retries with backoff, eventually succeeds.
    func test_401_retriesAndEventuallySucceeds() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        let lock = NSLock()
        nonisolated(unsafe) var attempts = 0
        MockURLProtocol.handler = { req in
            recorder.record(req)
            lock.lock(); attempts += 1; let n = attempts; lock.unlock()
            let code = n <= 3 ? 401 : 202
            return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        await h.core.track(event: "x", properties: nil)
        await settle(h.core)
        h.clock.advance(by: .seconds(5)) // first attempt
        await settle(h.core)
        for _ in 0..<6 {
            h.clock.advance(by: .seconds(60))
            await settle(h.core)
        }
        XCTAssertGreaterThanOrEqual(attempts, 4)
    }

    /// 6 — App backgrounded flushes pending events immediately (no 5s wait).
    func test_appBackgrounded_flushesImmediately() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        await h.core.track(event: "a", properties: nil)
        await settle(h.core)

        let before = recorder.count
        h.lifecycle.onBackground()
        await settle(h.core)
        XCTAssertEqual(recorder.count, before + 1)
    }

    /// 7 — Session rollover after 30-min idle (via lifecycle onActivate).
    func test_sessionRollover_afterIdle_emitsEndThenStart() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        await h.core.track(event: "a", properties: nil)
        await settle(h.core)

        // Simulate background + idle beyond timeout.
        h.clock.advance(by: .seconds(31 * 60))
        h.lifecycle.onActivate()
        await settle(h.core)

        // Flush.
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        var allNames: [String] = []
        for r in recorder.all() {
            allNames.append(contentsOf: eventNames(in: r.body))
        }
        XCTAssertTrue(allNames.contains("$session_start"))
        XCTAssertTrue(allNames.contains("$session_end"))
        XCTAssertTrue(allNames.contains("a"))
    }

    /// 8 — $session_end carries the PRIOR session id and timestamp.
    func test_sessionEnd_usesPriorSessionMetadata() async throws {
        let priorId = UUID()
        let priorLastActivity = Date(timeIntervalSinceReferenceDate: 100_000)
        let (h, _) = await makeHarness(initialSessionInDefaults: (priorId, priorLastActivity))
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        // Parse every POSTed event; find the $session_end; assert sessionId & timestamp.
        var endEvents: [[String: Any]] = []
        for r in recorder.all() {
            guard let json = try? JSONSerialization.jsonObject(with: r.body) else { continue }
            let arr: [[String: Any]] = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for d in arr where (d["event"] as? String) == "$session_end" {
                endEvents.append(d)
            }
        }
        XCTAssertEqual(endEvents.count, 1)
        let end = try XCTUnwrap(endEvents.first)
        XCTAssertEqual(end["sessionId"] as? String, priorId.uuidString)
    }

    /// 9 — Debug mode: local log only, no HTTP call, FSM still advances to .empty.
    func test_debugMode_logsInsteadOfPosting_andDisk_clears() async throws {
        let (h, _) = await makeHarness(debug: true)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        await h.core.track(event: "a", properties: nil)
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        XCTAssertEqual(recorder.count, 0, "debug mode must not call network")
        let remaining = try await h.disk.count()
        XCTAssertEqual(remaining, 0)
        let state = await h.core._state()
        XCTAssertEqual(state, .empty)
    }

    /// 10 — Disk rehydrate on start: pre-existing events are flushed.
    func test_diskRehydrateOnStart_flushesPreExistingEvents() async throws {
        let ev1 = AnalyticsEvent(event: "r1", deviceId: "d", userId: nil, sessionId: "s1", timestamp: Date(timeIntervalSinceReferenceDate: 0))
        let ev2 = AnalyticsEvent(event: "r2", deviceId: "d", userId: nil, sessionId: "s1", timestamp: Date(timeIntervalSinceReferenceDate: 1))
        let ev3 = AnalyticsEvent(event: "r3", deviceId: "d", userId: nil, sessionId: "s1", timestamp: Date(timeIntervalSinceReferenceDate: 2))
        let (h, _) = await makeHarness(prePopulatedDisk: [ev1, ev2, ev3])
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        var allNames: [String] = []
        for r in recorder.all() {
            allNames.append(contentsOf: eventNames(in: r.body))
        }
        XCTAssertTrue(allNames.contains("r1"))
        XCTAssertTrue(allNames.contains("r2"))
        XCTAssertTrue(allNames.contains("r3"))
    }

    /// 11 — identify() propagates userId to subsequent events.
    func test_identify_propagatesToEvents() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        await h.core.identify(userId: "user_42")
        await h.core.track(event: "x", properties: nil)
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        var seen: Set<String?> = []
        for r in recorder.all() {
            guard let json = try? JSONSerialization.jsonObject(with: r.body) else { continue }
            let arr: [[String: Any]] = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for d in arr where (d["event"] as? String) == "x" {
                seen.insert(d["userId"] as? String)
            }
        }
        XCTAssertTrue(seen.contains("user_42"))
    }

    /// 12 — reset() clears userId.
    func test_reset_clearsUserId() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        await h.core.identify(userId: "u")
        await h.core.reset()
        await h.core.track(event: "y", properties: nil)
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        for r in recorder.all() {
            guard let json = try? JSONSerialization.jsonObject(with: r.body) else { continue }
            let arr: [[String: Any]] = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for d in arr where (d["event"] as? String) == "y" {
                XCTAssertNil(d["userId"] as? String)
            }
        }
    }

    /// 13 — disable() no-ops track(): event not persisted, not sent.
    func test_disable_noOpsTrack() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        // Drain initial $session_start flush.
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        let before = recorder.count
        await h.core.setDisabled(true)
        await h.core.track(event: "nope", properties: nil)
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)
        XCTAssertEqual(recorder.count, before, "no new POST after disable")
        let remaining = try await h.disk.count()
        XCTAssertEqual(remaining, 0, "no new event on disk after disable")
    }

    /// 14 — enable() after disable() resumes tracking.
    func test_enableAfterDisable_resumes() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        await h.core.setDisabled(true)
        await h.core.track(event: "dropped", properties: nil)
        await settle(h.core)
        await h.core.setDisabled(false)
        await h.core.track(event: "kept", properties: nil)
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        var seenDropped = false, seenKept = false
        for r in recorder.all() {
            let names = eventNames(in: r.body)
            if names.contains("dropped") { seenDropped = true }
            if names.contains("kept") { seenKept = true }
        }
        XCTAssertFalse(seenDropped)
        XCTAssertTrue(seenKept)
    }

    /// 15 — FIFO mailbox under concurrent tracks: every event reaches the
    /// pipeline. Events may land either on disk (not yet flushed) or in a
    /// POST body (already flushed); either way, every one of the 100 names
    /// must appear in the union.
    func test_fifoMailbox_underConcurrentTracks() async throws {
        // Large batchLimit so no mid-stream batch flush races with the drain.
        // (Smaller limits would still pass if we summed disk + recorder, but
        // keeping a single-batch flow makes the FIFO guarantee explicit.)
        let (h, _) = await makeHarness(batchLimit: 1000)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { [core = h.core] in
                    await core.track(event: "e\(i)", properties: ["i": i])
                }
            }
        }
        await settle(h.core)

        var names = Set<String>()
        let diskEvents = try await h.disk.loadAll()
        for e in diskEvents { names.insert(e.event) }
        for r in recorder.all() { names.formUnion(eventNames(in: r.body)) }
        for i in 0..<100 { XCTAssertTrue(names.contains("e\(i)"), "missing e\(i)") }
    }

    /// 16 — Double start() is idempotent and warns.
    func test_doubleStart_isIdempotent() async throws {
        let (h, _) = await makeHarness()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await h.core.start() // second call must be a no-op (logs warning)
        await settle(h.core)

        // Single track should behave normally — the actor wasn't doubled up.
        await h.core.track(event: "once", properties: nil)
        await settle(h.core)
        let count = try await h.disk.count()
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    /// 17 — Foregrounded twice within the idle window: exactly one
    /// `$session_start` is emitted. Regression test for v1.1.0 bug where
    /// `handleActivate()` unconditionally emitted `$session_start` even when
    /// the session was reused.
    func test_doubleForeground_withinIdleWindow_emitsSingleSessionStart() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        // Foreground #1 (simulated): `start()` already emitted a
        // $session_start. Now fire onActivate to simulate the second
        // foreground 10 minutes later.
        h.clock.advance(by: .seconds(10 * 60))
        h.lifecycle.onActivate()
        await settle(h.core)

        // Flush so we can inspect what actually shipped.
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        var sessionStartCount = 0
        for r in recorder.all() {
            for name in eventNames(in: r.body) where name == "$session_start" {
                sessionStartCount += 1
            }
        }
        XCTAssertEqual(sessionStartCount, 1,
                       "Reused session within idle window must not re-emit $session_start")
    }

    /// 18 — `flush()` during `.backoff` forces an immediate retry. Regression
    /// test for v1.1.0 bug where `.backoff + .appBackgrounded` fell through
    /// to a no-op, so `flush()` returned without doing anything.
    func test_flush_duringBackoff_forcesImmediateRetry() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        let lock = NSLock()
        nonisolated(unsafe) var attempts = 0
        // First attempt fails (drives us into backoff); subsequent attempts
        // succeed so we can verify flush actually pushed through.
        MockURLProtocol.handler = { req in
            recorder.record(req)
            lock.lock(); attempts += 1; let n = attempts; lock.unlock()
            if n == 1 { throw URLError(.notConnectedToInternet) }
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        await h.core.track(event: "pending", properties: nil)
        await settle(h.core)

        // First flush fails → we transition to .backoff (timer armed for
        // ~1s + jitter).
        h.clock.advance(by: .seconds(5))
        await settle(h.core)
        XCTAssertEqual(attempts, 1, "should have tried once and failed")
        let stateAfterFail = await h.core._state()
        guard case .backoff = stateAfterFail else {
            XCTFail("expected .backoff state, got \(stateAfterFail)"); return
        }

        // flush() must force an immediate retry rather than waiting for the
        // backoff timer to fire.
        await h.core.flush()
        XCTAssertGreaterThanOrEqual(attempts, 2,
                                    "flush() in .backoff must force a retry, got only \(attempts) attempts")
    }

    /// 19 — Unencodable property value: key dropped, event still sent.
    func test_unencodableProperty_keyDropped_eventStillSent() async throws {
        let (h, _) = await makeHarness()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)

        // A Data value is not one of the AnyCodable-supported types (no implicit
        // conversion path), so AnyCodable(init:) throws and we drop the key.
        let bad: Any = Data([0x01, 0x02])
        await h.core.track(event: "mixed", properties: ["ok": 1, "bad": bad])
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        var saw = false
        for r in recorder.all() {
            guard let json = try? JSONSerialization.jsonObject(with: r.body) else { continue }
            let arr: [[String: Any]] = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for d in arr where (d["event"] as? String) == "mixed" {
                saw = true
                let props = d["properties"] as? [String: Any] ?? [:]
                XCTAssertNotNil(props["ok"])
                XCTAssertNil(props["bad"])
            }
        }
        XCTAssertTrue(saw, "mixed event should have been sent")
    }

    /// 21 — DeviceContext is merged into every tracked event: the six
    /// `$`-prefixed keys appear in the POSTed body with the injected values.
    func test_deviceContext_mergedIntoEveryEvent() async throws {
        let ctx = DeviceContext(
            appVersion: "1.4.2",
            appBuild: "842",
            buildType: "testflight",
            deviceType: "device",
            osName: "iOS",
            osVersion: "17.2.1"
        )
        let (h, _) = await makeHarness(deviceContext: ctx)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        await h.core.track(event: "tagged", properties: ["user_key": "u"])
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        var saw = false
        for r in recorder.all() {
            guard let json = try? JSONSerialization.jsonObject(with: r.body) else { continue }
            let arr: [[String: Any]] = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for d in arr where (d["event"] as? String) == "tagged" {
                saw = true
                let props = d["properties"] as? [String: Any] ?? [:]
                XCTAssertEqual(props["$app_version"] as? String, "1.4.2")
                XCTAssertEqual(props["$app_build"] as? String, "842")
                XCTAssertEqual(props["$build_type"] as? String, "testflight")
                XCTAssertEqual(props["$device_type"] as? String, "device")
                XCTAssertEqual(props["$os_name"] as? String, "iOS")
                XCTAssertEqual(props["$os_version"] as? String, "17.2.1")
                XCTAssertEqual(props["user_key"] as? String, "u")
            }
        }
        XCTAssertTrue(saw, "tagged event should have been sent")
    }

    /// 22 — System-owned reserved keys always win over user-supplied ones.
    /// A caller that puts `$app_version: "fake"` in properties must not be
    /// able to spoof the true app version on the wire.
    func test_deviceContext_userReservedKeys_areShadowed() async throws {
        let ctx = DeviceContext(
            appVersion: "real-1.0",
            appBuild: "1",
            buildType: "appstore",
            deviceType: "device",
            osName: "iOS",
            osVersion: "17.0.0"
        )
        let (h, _) = await makeHarness(deviceContext: ctx)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
        }
        await h.core.start()
        await settle(h.core)
        await h.core.track(event: "spoof", properties: [
            "$app_version": "fake-9.9",
            "$build_type": "debug",
            "legit": "ok",
        ])
        await settle(h.core)
        h.clock.advance(by: .seconds(5))
        await settle(h.core)

        var saw = false
        for r in recorder.all() {
            guard let json = try? JSONSerialization.jsonObject(with: r.body) else { continue }
            let arr: [[String: Any]] = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for d in arr where (d["event"] as? String) == "spoof" {
                saw = true
                let props = d["properties"] as? [String: Any] ?? [:]
                XCTAssertEqual(props["$app_version"] as? String, "real-1.0")
                XCTAssertEqual(props["$build_type"] as? String, "appstore")
                XCTAssertEqual(props["legit"] as? String, "ok")
            }
        }
        XCTAssertTrue(saw, "spoof event should have been sent")
    }
}
