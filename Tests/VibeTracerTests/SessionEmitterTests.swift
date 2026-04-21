import XCTest
@testable import VibeTracer

/// Pure-unit tests for `SessionEmitter`. No actor, no clock, no network —
/// just verifying the rollover→events mapping.
final class SessionEmitterTests: XCTestCase {

    private func makeEmitter(userId: String? = nil, now: Date = Date(timeIntervalSinceReferenceDate: 1_000_000))
        -> (SessionEmitter, UUID, UserIdStore, TestClock)
    {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let userIdStore = UserIdStore(defaults: defaults)
        if let uid = userId { userIdStore.identify(userId: uid) }
        let deviceId = UUID()
        let clock = TestClock(start: now)
        let emitter = SessionEmitter(
            deviceId: deviceId,
            userIdStore: userIdStore,
            clock: clock
        )
        return (emitter, deviceId, userIdStore, clock)
    }

    func test_reusedSession_producesZeroEvents() {
        let (emitter, _, _, _) = makeEmitter()
        let sid = UUID()
        let result = SessionRolloverResult(expired: nil, currentSessionId: sid, wasMinted: false)
        XCTAssertTrue(emitter.eventsFor(rollover: result).isEmpty)
    }

    func test_freshMint_producesSessionStartOnly() throws {
        let (emitter, deviceId, _, clock) = makeEmitter(userId: "u1")
        let sid = UUID()
        let result = SessionRolloverResult(expired: nil, currentSessionId: sid, wasMinted: true)

        let events = emitter.eventsFor(rollover: result)
        XCTAssertEqual(events.count, 1)
        let start = try XCTUnwrap(events.first)
        XCTAssertEqual(start.event, "$session_start")
        XCTAssertEqual(start.deviceId, deviceId.uuidString)
        XCTAssertEqual(start.userId, "u1")
        XCTAssertEqual(start.sessionId, sid.uuidString)
        XCTAssertEqual(start.timestamp.timeIntervalSinceReferenceDate,
                       clock.now().timeIntervalSinceReferenceDate,
                       accuracy: 0.001)
    }

    func test_expiredOnly_producesSessionEndOnly() throws {
        let (emitter, deviceId, _, _) = makeEmitter()
        let priorId = UUID()
        let priorActivity = Date(timeIntervalSinceReferenceDate: 500_000)
        let stillLive = UUID()
        let result = SessionRolloverResult(
            expired: ExpiredSession(sessionId: priorId, lastActivityAt: priorActivity),
            currentSessionId: stillLive,
            wasMinted: false
        )

        let events = emitter.eventsFor(rollover: result)
        XCTAssertEqual(events.count, 1)
        let end = try XCTUnwrap(events.first)
        XCTAssertEqual(end.event, "$session_end")
        XCTAssertEqual(end.deviceId, deviceId.uuidString)
        XCTAssertEqual(end.sessionId, priorId.uuidString,
                       "session_end must carry the PRIOR session id")
        XCTAssertEqual(end.timestamp.timeIntervalSinceReferenceDate,
                       priorActivity.timeIntervalSinceReferenceDate,
                       accuracy: 0.001,
                       "session_end must carry the last-activity timestamp of the prior session")
    }

    func test_expiredAndMinted_producesEndThenStart_inOrder() throws {
        let (emitter, _, _, clock) = makeEmitter()
        let priorId = UUID()
        let priorActivity = Date(timeIntervalSinceReferenceDate: 500_000)
        let newId = UUID()
        let result = SessionRolloverResult(
            expired: ExpiredSession(sessionId: priorId, lastActivityAt: priorActivity),
            currentSessionId: newId,
            wasMinted: true
        )

        let events = emitter.eventsFor(rollover: result)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "$session_end")
        XCTAssertEqual(events[0].sessionId, priorId.uuidString)
        XCTAssertEqual(events[1].event, "$session_start")
        XCTAssertEqual(events[1].sessionId, newId.uuidString)
        XCTAssertEqual(events[1].timestamp.timeIntervalSinceReferenceDate,
                       clock.now().timeIntervalSinceReferenceDate,
                       accuracy: 0.001)
    }
}
