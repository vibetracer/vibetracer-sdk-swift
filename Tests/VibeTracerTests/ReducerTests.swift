import XCTest
@testable import VibeTracer

final class ReducerTests: XCTestCase {

    // Helper — unique event each call so set-equality assertions are meaningful.
    private func makeEvent(_ name: String = "x") -> AnalyticsEvent {
        AnalyticsEvent(event: name, deviceId: "d", userId: nil, sessionId: "s")
    }

    // MARK: - empty transitions

    func test_empty_plus_track_goesToQueuing_andPersists_andSchedulesTimer() {
        let e = makeEvent()
        let (state, effects) = reduce(.empty, .track(e), batchLimit: 20)
        XCTAssertEqual(state, .queuing)
        XCTAssertEqual(effects, [
            .persistToDisk(events: [e]),
            .scheduleTimer(after: .seconds(5)),
        ])
    }

    func test_empty_plus_timer_staysEmpty_noEffects() {
        let (s, fx) = reduce(.empty, .timerFired, batchLimit: 20)
        XCTAssertEqual(s, .empty)
        XCTAssertTrue(fx.isEmpty)
    }

    func test_empty_plus_appBackgrounded_staysEmpty_noEffects() {
        let (s, fx) = reduce(.empty, .appBackgrounded, batchLimit: 20)
        XCTAssertEqual(s, .empty)
        XCTAssertTrue(fx.isEmpty)
    }

    // MARK: - queuing transitions

    func test_queuing_plus_track_stillQueuing_ifBelowLimit() {
        let e = makeEvent()
        let (s, fx) = reduce(.queuing, .track(e), batchLimit: 20)
        XCTAssertEqual(s, .queuing)
        XCTAssertEqual(fx, [.persistToDisk(events: [e])])
        // No new timer; existing timer from earlier still ticks.
    }

    func test_queuing_plus_timer_nonemptyBatch_goesToFlushing() {
        let batch = [makeEvent("a"), makeEvent("b")]
        let (s, fx) = reduce(.queuing, .timerFired, batchLimit: 20, currentBatch: batch)
        XCTAssertEqual(s, .flushing(batch: batch))
        XCTAssertEqual(fx, [.httpPost(batch: batch)])
    }

    func test_queuing_plus_timer_emptyBatch_goesToEmpty() {
        let (s, fx) = reduce(.queuing, .timerFired, batchLimit: 20, currentBatch: [])
        XCTAssertEqual(s, .empty)
        XCTAssertTrue(fx.isEmpty)
    }

    func test_queuing_plus_batchFull_goesToFlushing() {
        let e = makeEvent()
        let batch = (0..<20).map { _ in e }
        let (s, fx) = reduce(.queuing, .batchFull, batchLimit: 20, currentBatch: batch)
        XCTAssertEqual(s, .flushing(batch: batch))
        XCTAssertEqual(fx, [.cancelTimer, .httpPost(batch: batch)])
    }

    func test_queuing_plus_appBackgrounded_flushesIfNonempty() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.queuing, .appBackgrounded, batchLimit: 20, currentBatch: batch)
        XCTAssertEqual(s, .flushing(batch: batch))
        XCTAssertEqual(fx, [.cancelTimer, .httpPost(batch: batch)])
    }

    // MARK: - flushing transitions

    func test_flushing_plus_sendOk_goesToEmpty_ifNoMore() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.flushing(batch: batch), .sendOk(batch: batch),
                             batchLimit: 20, currentBatch: [])
        XCTAssertEqual(s, .empty)
        XCTAssertEqual(fx, [.removeFromDisk(eventIds: [batch[0].clientEventId])])
    }

    func test_flushing_plus_sendOk_goesToQueuing_ifMore() {
        let batch = [makeEvent("a")]
        let more = [makeEvent("b"), makeEvent("c")]
        let (s, fx) = reduce(.flushing(batch: batch), .sendOk(batch: batch),
                             batchLimit: 20, currentBatch: more)
        XCTAssertEqual(s, .queuing)
        XCTAssertEqual(fx, [
            .removeFromDisk(eventIds: [batch[0].clientEventId]),
            .scheduleTimer(after: .seconds(5)),
        ])
    }

    /// Stall-recovery: if the ack doesn't match the in-flight batch by id,
    /// self-heal to `.queuing` rather than silently eating the callback.
    func test_flushing_plus_sendOk_mismatchedIds_selfHealsToQueuing() {
        let inFlight = [makeEvent("a"), makeEvent("b")]
        let wrongAck = [makeEvent("x"), makeEvent("y")]   // same count, different ids
        let (s, fx) = reduce(.flushing(batch: inFlight), .sendOk(batch: wrongAck),
                             batchLimit: 20, currentBatch: [])
        XCTAssertEqual(s, .queuing)
        // No removeFromDisk (we don't know which ids actually shipped) and
        // no scheduleTimer duplication (caller re-arms on next track).
        XCTAssertTrue(fx.isEmpty)
    }

    func test_flushing_plus_sendFailed_retryable_goesToBackoff_attempt1() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.flushing(batch: batch),
                             .sendFailed(batch: batch, permanent: false, retryAfter: nil),
                             batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 1, pendingBatch: batch))
        guard case .scheduleTimer(after: _) = fx.first else {
            XCTFail("expected scheduleTimer"); return
        }
        XCTAssertEqual(fx.count, 1)
    }

    func test_flushing_plus_sendFailed_retryable_withRetryAfter_usesHint() {
        // Server-provided Retry-After overrides the exp-backoff ladder for
        // this attempt. The attempt counter still resets to 1 (this is the
        // first failure of the in-flight batch) but the scheduleTimer uses
        // the hint directly.
        let batch = [makeEvent()]
        let (s, fx) = reduce(.flushing(batch: batch),
                             .sendFailed(batch: batch, permanent: false, retryAfter: .seconds(17)),
                             batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 1, pendingBatch: batch))
        XCTAssertEqual(fx, [.scheduleTimer(after: .seconds(17))])
    }

    func test_flushing_plus_sendFailed_permanent_dropsBatch_andReturnsToEmpty() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.flushing(batch: batch),
                             .sendFailed(batch: batch, permanent: true, retryAfter: nil),
                             batchLimit: 20)
        XCTAssertEqual(s, .empty)
        XCTAssertEqual(fx, [
            .removeFromDisk(eventIds: [batch[0].clientEventId]),
            .batchDropped(reason: "permanent_client_error", count: 1),
        ])
    }

    func test_flushing_plus_track_persistsWhileFlightInFlight() {
        let inFlight = [makeEvent("a")]
        let newE = makeEvent("b")
        let (s, fx) = reduce(.flushing(batch: inFlight), .track(newE), batchLimit: 20)
        XCTAssertEqual(s, .flushing(batch: inFlight))
        XCTAssertEqual(fx, [.persistToDisk(events: [newE])])
    }

    // MARK: - backoff transitions

    func test_backoff_plus_expired_goesToFlushing_sameBatch() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.backoff(attempt: 3, pendingBatch: batch),
                             .backoffExpired, batchLimit: 20)
        XCTAssertEqual(s, .flushing(batch: batch))
        XCTAssertEqual(fx, [.httpPost(batch: batch)])
    }

    func test_backoff_plus_track_persistsButStaysInBackoff() {
        let e = makeEvent("new")
        let batch = [makeEvent("old")]
        let (s, fx) = reduce(.backoff(attempt: 2, pendingBatch: batch),
                             .track(e), batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 2, pendingBatch: batch))
        XCTAssertEqual(fx, [.persistToDisk(events: [e])])
    }

    func test_backoff_plus_appTerminating_staysInBackoff_noNetwork() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.backoff(attempt: 1, pendingBatch: batch),
                             .appTerminating, batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 1, pendingBatch: batch))   // state preserved for next launch
        XCTAssertTrue(fx.isEmpty)                                      // no network
    }

    func test_backoff_plus_sendFailed_permanent_dropsAndGoesToEmpty() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.backoff(attempt: 4, pendingBatch: batch),
                             .sendFailed(batch: batch, permanent: true, retryAfter: nil),
                             batchLimit: 20)
        XCTAssertEqual(s, .empty)
        XCTAssertEqual(fx, [
            .removeFromDisk(eventIds: [batch[0].clientEventId]),
            .batchDropped(reason: "permanent_client_error", count: 1),
        ])
    }

    func test_backoff_plus_sendFailed_retryable_advancesAttempt_andUsesLadder() {
        // No server hint → exp-backoff ladder at attempt n+1. At attempt=3,
        // ladder base is 4s; with jitter in [0.8, 1.2], result is in
        // [3.2s, 4.8s]. Assert state transition and timer existence; the
        // jitter range is covered by computeBackoff's own tests.
        let batch = [makeEvent()]
        let (s, fx) = reduce(.backoff(attempt: 2, pendingBatch: batch),
                             .sendFailed(batch: batch, permanent: false, retryAfter: nil),
                             batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 3, pendingBatch: batch))
        guard case .scheduleTimer(after: _) = fx.first, fx.count == 1 else {
            XCTFail("expected exactly one scheduleTimer effect, got \(fx)")
            return
        }
    }

    func test_backoff_plus_sendFailed_retryable_withRetryAfter_overridesLadder() {
        // Hint wins: attempt counter still advances, but the delay is taken
        // from the server rather than computeBackoff(attempt: n+1).
        let batch = [makeEvent()]
        let (s, fx) = reduce(.backoff(attempt: 5, pendingBatch: batch),
                             .sendFailed(batch: batch, permanent: false, retryAfter: .seconds(42)),
                             batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 6, pendingBatch: batch))
        XCTAssertEqual(fx, [.scheduleTimer(after: .seconds(42))])
    }

    // MARK: - computeBackoff

    func test_computeBackoff_ladder_noJitter() {
        // Jitter rng=1.0 ⇒ exactly the base delay each step.
        XCTAssertEqual(computeBackoff(attempt: 1, rng: 1.0), .seconds(1))
        XCTAssertEqual(computeBackoff(attempt: 2, rng: 1.0), .seconds(2))
        XCTAssertEqual(computeBackoff(attempt: 3, rng: 1.0), .seconds(4))
        XCTAssertEqual(computeBackoff(attempt: 4, rng: 1.0), .seconds(8))
        XCTAssertEqual(computeBackoff(attempt: 5, rng: 1.0), .seconds(16))
        XCTAssertEqual(computeBackoff(attempt: 6, rng: 1.0), .seconds(32))
        XCTAssertEqual(computeBackoff(attempt: 7, rng: 1.0), .seconds(60))
        XCTAssertEqual(computeBackoff(attempt: 8, rng: 1.0), .seconds(60))   // capped
        XCTAssertEqual(computeBackoff(attempt: 100, rng: 1.0), .seconds(60))
    }

    func test_computeBackoff_jitter_lowAndHigh() {
        // At attempt=3 the base is 4s.
        XCTAssertEqual(computeBackoff(attempt: 3, rng: 0.8), .milliseconds(3200))
        XCTAssertEqual(computeBackoff(attempt: 3, rng: 1.2), .milliseconds(4800))
    }

    // MARK: - flushRequested transitions (v1.1.1)

    func test_empty_plus_flushRequested_isNoOp() {
        let (s, fx) = reduce(.empty, .flushRequested, batchLimit: 20)
        XCTAssertEqual(s, .empty)
        XCTAssertTrue(fx.isEmpty)
    }

    func test_queuing_plus_flushRequested_emptyBatch_isNoOp() {
        let (s, fx) = reduce(.queuing, .flushRequested, batchLimit: 20, currentBatch: [])
        XCTAssertEqual(s, .queuing)
        XCTAssertTrue(fx.isEmpty)
    }

    func test_queuing_plus_flushRequested_nonemptyBatch_flushesImmediately() {
        let batch = [makeEvent("a"), makeEvent("b")]
        let (s, fx) = reduce(.queuing, .flushRequested, batchLimit: 20, currentBatch: batch)
        XCTAssertEqual(s, .flushing(batch: batch))
        XCTAssertEqual(fx, [.cancelTimer, .httpPost(batch: batch)])
    }

    func test_flushing_plus_flushRequested_staysFlushing() {
        let inFlight = [makeEvent("a")]
        let (s, fx) = reduce(.flushing(batch: inFlight), .flushRequested, batchLimit: 20)
        XCTAssertEqual(s, .flushing(batch: inFlight))
        XCTAssertTrue(fx.isEmpty)
    }

    func test_backoff_plus_flushRequested_forcesImmediateRetry() {
        let batch = [makeEvent("pending")]
        let (s, fx) = reduce(.backoff(attempt: 3, pendingBatch: batch),
                             .flushRequested, batchLimit: 20)
        XCTAssertEqual(s, .flushing(batch: batch))
        XCTAssertEqual(fx, [.cancelTimer, .httpPost(batch: batch)])
    }

    /// Guard against regressing the bug that motivated `.flushRequested`:
    /// `.appBackgrounded` must NOT force a retry from `.backoff` (the OS is
    /// suspending us and the backoff timer is already handling this).
    func test_backoff_plus_appBackgrounded_doesNotForceRetry() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.backoff(attempt: 2, pendingBatch: batch),
                             .appBackgrounded, batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 2, pendingBatch: batch))
        XCTAssertTrue(fx.isEmpty)
    }

    func test_computeBackoff_jitterBounded_monotonic() {
        for attempt in 1...10 {
            let dLow = computeBackoff(attempt: attempt, rng: 0.8)
            let dHigh = computeBackoff(attempt: attempt, rng: 1.2)
            XCTAssertLessThanOrEqual(dLow, dHigh)
        }
    }
}
