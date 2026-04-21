import XCTest
@testable import VibeTracer

/// Tests for `VibeTracer.trackDebounced` / `cancelDebounced`.
///
/// Debounce behavior is observable end-to-end: the mock network captures every
/// outbound batch, and we assert on event counts + the properties payload that
/// was attached at fire time. We deliberately go through the real FSM mailbox
/// rather than peeking at the private `debounceWorkItems` dict, so a regression
/// in scheduling OR in the track-at-fire-time behavior gets caught.
///
/// Timings are chosen conservatively for CI: 0.2–0.3s debounce windows with
/// a settle grace of ~0.5s after the window ends, which is enough slack for a
/// loaded macOS CI runner to emit the event without this suite becoming slow.
final class VibeTracerDebounceTests: XCTestCase {

    private func makeMockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override func setUp() async throws {
        try await super.setUp()
        #if DEBUG
        VibeTracer.resetForTesting()
        #endif
        UserDefaults.standard.removeObject(forKey: "com.vibetracer.disabled")
        VibeTracer.configure(
            apiKey: "vtr_test_debounce",
            endpoint: URL(string: "https://api.vibetracer.xyz")!,
            debug: false,
            urlSession: makeMockSession()
        )
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        #if DEBUG
        VibeTracer.resetForTesting()
        #endif
        UserDefaults.standard.removeObject(forKey: "com.vibetracer.disabled")
        try await super.tearDown()
    }

    /// 1 — single call fires after the debounce window elapses.
    func test_singleCall_firesAfterWindow() async throws {
        let recorder = EventRecorder()
        MockURLProtocol.handler = recorder.makeHandler()

        VibeTracer.trackDebounced("single_fire", debounce: 0.2) { ["n": 1] }
        try await Task.sleep(nanoseconds: 700_000_000)
        await VibeTracer.flush()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(recorder.count(of: "single_fire"), 1)
    }

    /// 2 — rapid-fire calls coalesce into ONE event. This is the core
    /// guarantee — an agent that ships settled-state tracking with
    /// `trackDebounced` relies on this to not flood the pipeline.
    func test_rapidFire_coalescesToSingleEvent() async throws {
        let recorder = EventRecorder()
        MockURLProtocol.handler = recorder.makeHandler()

        for i in 1...8 {
            VibeTracer.trackDebounced("coalesce_me", debounce: 0.3) { ["attempt": i] }
            try await Task.sleep(nanoseconds: 30_000_000)  // 30ms between calls (< 300ms window)
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        await VibeTracer.flush()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(recorder.count(of: "coalesce_me"), 1, "rapid-fire calls must coalesce")
    }

    /// 3 — properties closure is invoked at fire time (not at call time), so
    /// the event carries the LATEST state when the debounce window settles.
    func test_propertiesEvaluatedAtFireTime() async throws {
        let recorder = EventRecorder()
        MockURLProtocol.handler = recorder.makeHandler()

        // Mutable state captured by reference via a box — simulates a
        // @State var in a SwiftUI view that the user updates between calls.
        let box = Box(value: 0)
        for i in 1...5 {
            box.value = i
            VibeTracer.trackDebounced("latest_state", debounce: 0.2) { ["v": box.value] }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        await VibeTracer.flush()
        try await Task.sleep(nanoseconds: 200_000_000)

        let props = recorder.propertiesOfLast("latest_state")
        XCTAssertEqual(props?["v"] as? Int, 5, "closure should see the mutation before fire")
    }

    /// 4 — different event names don't interfere; both fire after their
    /// windows, independently.
    func test_differentEvents_bothFire() async throws {
        let recorder = EventRecorder()
        MockURLProtocol.handler = recorder.makeHandler()

        VibeTracer.trackDebounced("alpha", debounce: 0.2) { ["side": "A"] }
        VibeTracer.trackDebounced("bravo", debounce: 0.2) { ["side": "B"] }
        try await Task.sleep(nanoseconds: 700_000_000)
        await VibeTracer.flush()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(recorder.count(of: "alpha"), 1)
        XCTAssertEqual(recorder.count(of: "bravo"), 1)
    }

    /// 5 — same event, different keys → both fire (caller used `key:` to
    /// keep independent instances from cancelling each other, e.g. two rows
    /// in a list that each debounce their own edits).
    func test_sameEventDifferentKeys_bothFire() async throws {
        let recorder = EventRecorder()
        MockURLProtocol.handler = recorder.makeHandler()

        VibeTracer.trackDebounced("row_edited", key: "row-1", debounce: 0.2) { ["row": 1] }
        VibeTracer.trackDebounced("row_edited", key: "row-2", debounce: 0.2) { ["row": 2] }
        try await Task.sleep(nanoseconds: 700_000_000)
        await VibeTracer.flush()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(recorder.count(of: "row_edited"), 2, "different keys should not coalesce")
    }

    /// 6 — `cancelDebounced` on a pending call prevents it from firing. The
    /// `.onDisappear` use case.
    func test_cancelDebounced_preventsFire() async throws {
        let recorder = EventRecorder()
        MockURLProtocol.handler = recorder.makeHandler()

        VibeTracer.trackDebounced("should_not_fire", debounce: 0.5) { ["x": 1] }
        try await Task.sleep(nanoseconds: 100_000_000)  // still within window
        VibeTracer.cancelDebounced("should_not_fire")
        try await Task.sleep(nanoseconds: 900_000_000)  // well past original window
        await VibeTracer.flush()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(recorder.count(of: "should_not_fire"), 0)
    }

    // MARK: - Helpers

    /// Reference-type box so a closure can read mutations from outside.
    /// Tests run single-threaded enough that a plain class without locking
    /// is fine — tighter synchronization would only mask timing bugs we want
    /// to see.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(value: T) { self.value = value }
    }

    /// Captures every outbound POST body into a list of event records so
    /// tests can assert on counts and the latest-fired properties dict.
    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [[String: Any]] = []

        func makeHandler() -> (URLRequest) -> (HTTPURLResponse, Data) {
            return { [weak self] req in
                if let self, let body = Self.extractBody(req),
                   let json = try? JSONSerialization.jsonObject(with: body) {
                    let arr: [[String: Any]] =
                        (json as? [[String: Any]])
                        ?? [(json as? [String: Any])].compactMap { $0 }
                    self.lock.lock()
                    self.records.append(contentsOf: arr)
                    self.lock.unlock()
                }
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
        }

        func count(of event: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return records.filter { ($0["event"] as? String) == event }.count
        }

        func propertiesOfLast(_ event: String) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            return records.last(where: { ($0["event"] as? String) == event })?["properties"] as? [String: Any]
        }

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
}
