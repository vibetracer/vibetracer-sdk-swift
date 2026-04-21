import XCTest
@testable import VibeTracer

final class SessionTrackerTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    // MARK: - Keys (mirrored from SessionTracker for priming tests)

    private static let sessionIdKey = "com.vibetracer.sessionId"
    private static let lastActivityKey = "com.vibetracer.sessionLastActivityAt"

    // MARK: - 1. New installation

    func test_newInstallation_reportsNoExpiredPriorAndMintsFresh() {
        let defaults = makeDefaults()
        let clock = TestClock(start: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let tracker = SessionTracker(defaults: defaults, clock: clock)

        XCTAssertNil(tracker.takeExpiredPriorSession())
        let sid = tracker.startSessionIfNeeded()
        XCTAssertEqual(sid.uuidString.count, 36)
        XCTAssertEqual(tracker.currentSessionId, sid)
    }

    // MARK: - 2. Active session reuses

    func test_activeSession_reusesWithinIdleWindow() {
        let defaults = makeDefaults()
        let clock = TestClock(start: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let tracker = SessionTracker(defaults: defaults, clock: clock)

        let first = tracker.startSessionIfNeeded()
        tracker.noteActivity()
        clock.advance(by: .seconds(10 * 60))
        let second = tracker.startSessionIfNeeded()

        XCTAssertEqual(first, second)
        XCTAssertEqual(tracker.currentSessionId, first)
    }

    // MARK: - 3. Idle > 30 min mints new

    func test_idleBeyond30Min_mintsNewSessionAndReportsPriorExpired() throws {
        let defaults = makeDefaults()
        let clock = TestClock(start: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let tracker = SessionTracker(defaults: defaults, clock: clock)

        let a = tracker.startSessionIfNeeded()
        tracker.noteActivity()
        let lastActivity = clock.now()

        clock.advance(by: .seconds(31 * 60))

        let expired = try XCTUnwrap(tracker.takeExpiredPriorSession())
        XCTAssertEqual(expired.sessionId, a)
        XCTAssertEqual(expired.lastActivityAt.timeIntervalSinceReferenceDate,
                       lastActivity.timeIntervalSinceReferenceDate,
                       accuracy: 0.001)

        let b = tracker.startSessionIfNeeded()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(tracker.currentSessionId, b)
    }

    // MARK: - 4. Prior session expired on next launch

    func test_priorSessionExpired_detectedOnNextLaunch() throws {
        let defaults = makeDefaults()
        let priorId = UUID()
        let launchTime = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let priorActivity = launchTime.addingTimeInterval(-31 * 60)

        defaults.set(priorId.uuidString, forKey: Self.sessionIdKey)
        defaults.set(priorActivity.timeIntervalSinceReferenceDate, forKey: Self.lastActivityKey)

        let clock = TestClock(start: launchTime)
        let tracker = SessionTracker(defaults: defaults, clock: clock)

        let expired = try XCTUnwrap(tracker.takeExpiredPriorSession())
        XCTAssertEqual(expired.sessionId, priorId)
        XCTAssertEqual(expired.lastActivityAt.timeIntervalSinceReferenceDate,
                       priorActivity.timeIntervalSinceReferenceDate,
                       accuracy: 0.001)
        XCTAssertNil(tracker.currentSessionId,
                     "currentSessionId should stay nil until startSessionIfNeeded is called")
    }

    // MARK: - 5. takeExpiredPriorSession is idempotent

    func test_takeExpiredPriorSession_isIdempotentUntilConsumed() throws {
        let defaults = makeDefaults()
        let priorId = UUID()
        let launchTime = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let priorActivity = launchTime.addingTimeInterval(-31 * 60)

        defaults.set(priorId.uuidString, forKey: Self.sessionIdKey)
        defaults.set(priorActivity.timeIntervalSinceReferenceDate, forKey: Self.lastActivityKey)

        let clock = TestClock(start: launchTime)
        let tracker = SessionTracker(defaults: defaults, clock: clock)

        let first = try XCTUnwrap(tracker.takeExpiredPriorSession())
        let second = try XCTUnwrap(tracker.takeExpiredPriorSession())
        XCTAssertEqual(first.sessionId, second.sessionId)
        XCTAssertEqual(first.lastActivityAt.timeIntervalSinceReferenceDate,
                       second.lastActivityAt.timeIntervalSinceReferenceDate,
                       accuracy: 0.001)

        // Consume by starting a new session.
        _ = tracker.startSessionIfNeeded()
        XCTAssertNil(tracker.takeExpiredPriorSession())
    }

    // MARK: - 6. Concurrent noteActivity

    func test_concurrentNoteActivity_doesNotCorruptState() {
        let defaults = makeDefaults()
        let start = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let clock = TestClock(start: start)
        let tracker = SessionTracker(defaults: defaults, clock: clock)
        _ = tracker.startSessionIfNeeded()

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            tracker.noteActivity()
        }

        // No corruption: currentSessionId is still valid and the stored
        // lastActivity is a finite double close to clock.now().
        XCTAssertNotNil(tracker.currentSessionId)

        let stored = defaults.double(forKey: Self.lastActivityKey)
        XCTAssertTrue(stored.isFinite)
        XCTAssertEqual(stored, start.timeIntervalSinceReferenceDate, accuracy: 0.001)

        // And the stored session id round-trips.
        let sidString = defaults.string(forKey: Self.sessionIdKey)
        XCTAssertNotNil(sidString.flatMap(UUID.init(uuidString:)))
    }

    // MARK: - 7. Malformed stored UUID

    func test_malformedStoredSessionId_isTreatedAsMissing() {
        let defaults = makeDefaults()
        defaults.set("not-a-uuid", forKey: Self.sessionIdKey)
        defaults.set(Date().timeIntervalSinceReferenceDate, forKey: Self.lastActivityKey)

        let clock = TestClock(start: Date(timeIntervalSinceReferenceDate: 4_000_000))
        let tracker = SessionTracker(defaults: defaults, clock: clock)

        XCTAssertNil(tracker.takeExpiredPriorSession())
        let minted = tracker.startSessionIfNeeded()
        XCTAssertEqual(minted.uuidString.count, 36)
    }

    // MARK: - 8. Clock going backwards

    func test_clockGoingBackwards_doesNotTriggerRollover() {
        let defaults = makeDefaults()
        let t = Date(timeIntervalSinceReferenceDate: 5_000_000)
        let clock = TestClock(start: t)
        let tracker = SessionTracker(defaults: defaults, clock: clock)

        let a = tracker.startSessionIfNeeded()
        tracker.noteActivity()

        // Simulate system clock being rolled back by 10 minutes.
        clock.advance(by: .seconds(-10 * 60))

        XCTAssertNil(tracker.takeExpiredPriorSession())
        let b = tracker.startSessionIfNeeded()
        XCTAssertEqual(a, b, "Negative age must not trigger session rollover")
    }
}
