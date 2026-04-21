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
        // First attempt for this batch — attempt starts at 1.
        XCTAssertEqual(s, .flushing(batch: batch, attempt: 1))
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
        XCTAssertEqual(s, .flushing(batch: batch, attempt: 1))
        XCTAssertEqual(fx, [.cancelTimer, .httpPost(batch: batch)])
    }

    func test_queuing_plus_appBackgrounded_flushesIfNonempty() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.queuing, .appBackgrounded, batchLimit: 20, currentBatch: batch)
        XCTAssertEqual(s, .flushing(batch: batch, attempt: 1))
        XCTAssertEqual(fx, [.cancelTimer, .httpPost(batch: batch)])
    }

    // MARK: - flushing transitions

    func test_flushing_plus_sendOk_goesToEmpty_ifNoMore() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.flushing(batch: batch, attempt: 1), .sendOk(batch: batch),
                             batchLimit: 20, currentBatch: [])
        XCTAssertEqual(s, .empty)
        XCTAssertEqual(fx, [.removeFromDisk(eventIds: [batch[0].clientEventId])])
    }

    func test_flushing_plus_sendOk_goesToQueuing_ifMore() {
        let batch = [makeEvent("a")]
        let more = [makeEvent("b"), makeEvent("c")]
        let (s, fx) = reduce(.flushing(batch: batch, attempt: 1), .sendOk(batch: batch),
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
        let (s, fx) = reduce(.flushing(batch: inFlight, attempt: 1), .sendOk(batch: wrongAck),
                             batchLimit: 20, currentBatch: [])
        XCTAssertEqual(s, .queuing)
        // No removeFromDisk (we don't know which ids actually shipped) and
        // no scheduleTimer duplication (caller re-arms on next track).
        XCTAssertTrue(fx.isEmpty)
    }

    func test_flushing_plus_sendFailed_retryable_carriesAttemptIntoBackoff() {
        // First-attempt failure: .flushing(attempt: 1) → .backoff(attempt: 1)
        // with delay = computeBackoff(attempt: 1). The backoff's attempt equals
        // the attempt that JUST FAILED; the next retry (.backoffExpired) will
        // run as attempt 2.
        let batch = [makeEvent()]
        let (s, fx) = reduce(.flushing(batch: batch, attempt: 1),
                             .sendFailed(batch: batch, permanent: false, retryAfter: nil),
                             batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 1, pendingBatch: batch))
        guard case .scheduleTimer(after: _) = fx.first else {
            XCTFail("expected scheduleTimer"); return
        }
        XCTAssertEqual(fx.count, 1)
    }

    func test_flushing_plus_sendFailed_retryable_attempt3_schedulesLadder3s() {
        // Direct verification that .flushing's attempt counter feeds
        // computeBackoff. At attempt=3, base=4s; with the default jittered
        // rng we can't assert the exact Duration, but we CAN assert the
        // state carries attempt=3 into .backoff, and the rest is covered by
        // computeBackoff unit tests + the multi-round integration test below.
        let batch = [makeEvent()]
        let (s, fx) = reduce(.flushing(batch: batch, attempt: 3),
                             .sendFailed(batch: batch, permanent: false, retryAfter: nil),
                             batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 3, pendingBatch: batch))
        XCTAssertEqual(fx.count, 1)
    }

    func test_flushing_plus_sendFailed_retryable_withRetryAfter_usesHint() {
        // Server-provided Retry-After overrides the exp-backoff ladder for
        // this wait. The attempt counter is preserved (not reset) so that
        // if the next retry fails without a hint, the ladder continues at
        // the correct rung.
        let batch = [makeEvent()]
        let (s, fx) = reduce(.flushing(batch: batch, attempt: 4),
                             .sendFailed(batch: batch, permanent: false, retryAfter: .seconds(17)),
                             batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 4, pendingBatch: batch))
        XCTAssertEqual(fx, [.scheduleTimer(after: .seconds(17))])
    }

    func test_flushing_plus_sendFailed_permanent_dropsBatch_andReturnsToEmpty() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.flushing(batch: batch, attempt: 1),
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
        let (s, fx) = reduce(.flushing(batch: inFlight, attempt: 1), .track(newE), batchLimit: 20)
        XCTAssertEqual(s, .flushing(batch: inFlight, attempt: 1))
        XCTAssertEqual(fx, [.persistToDisk(events: [newE])])
    }

    /// Integration over the reducer: simulate the full flush→backoff→flush
    /// loop to prove the exp-backoff ladder actually climbs across round-
    /// trips (the pre-v1.1.3 FSM reset attempt to 1 every time, so the
    /// ladder never moved off 1s — the 10k disk cap was effectively our
    /// only retry pressure bound during outages). This test walks four
    /// consecutive failures and checks the .backoff attempt advances 1→2→3→4.
    func test_reducer_ladderClimbsAcrossFlushBackoffRoundTrips() {
        let batch = [makeEvent()]
        var state: QueueState = .flushing(batch: batch, attempt: 1)

        for expectedAttempt in 1...4 {
            // .flushing(attempt: n) + .sendFailed → .backoff(attempt: n)
            let (afterFail, _) = reduce(state,
                                        .sendFailed(batch: batch, permanent: false, retryAfter: nil),
                                        batchLimit: 20)
            XCTAssertEqual(afterFail, .backoff(attempt: expectedAttempt, pendingBatch: batch),
                           "after failure #\(expectedAttempt), backoff must carry attempt=\(expectedAttempt)")

            // .backoff(n) + .backoffExpired → .flushing(attempt: n+1)
            let (afterExpire, fx) = reduce(afterFail, .backoffExpired,
                                           batchLimit: 20, currentBatch: [])
            XCTAssertEqual(afterExpire, .flushing(batch: batch, attempt: expectedAttempt + 1),
                           "retry after backoff #\(expectedAttempt) must run as attempt \(expectedAttempt + 1)")
            XCTAssertEqual(fx, [.httpPost(batch: batch)])
            state = afterExpire
        }
    }

    // MARK: - backoff transitions

    func test_backoff_plus_expired_advancesAttempt_andGoesToFlushing() {
        // .backoff(attempt: 3) = "attempt 3 just failed, waiting". On expiry
        // we run attempt 4 — .flushing carries the advanced counter so
        // if that attempt also fails the next backoff uses the right rung.
        let batch = [makeEvent()]
        let (s, fx) = reduce(.backoff(attempt: 3, pendingBatch: batch),
                             .backoffExpired, batchLimit: 20)
        XCTAssertEqual(s, .flushing(batch: batch, attempt: 4))
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

    /// `.sendFailed` is only emitted by the runner after `.httpPost`, which
    /// only runs from `.flushing`. The mailbox drain is serial so state is
    /// always `.flushing` when the callback lands — the `.flushing + .sendFailed`
    /// branch is authoritative. This test documents the defensive no-op for
    /// the otherwise unreachable case: if some future reentrancy or signal
    /// routing delivers `.sendFailed` in `.backoff`, we preserve state rather
    /// than double-advancing the attempt counter.
    func test_backoff_plus_sendFailed_isDefensiveNoOp() {
        let batch = [makeEvent()]
        let (s, fx) = reduce(.backoff(attempt: 4, pendingBatch: batch),
                             .sendFailed(batch: batch, permanent: false, retryAfter: nil),
                             batchLimit: 20)
        XCTAssertEqual(s, .backoff(attempt: 4, pendingBatch: batch))
        XCTAssertTrue(fx.isEmpty)

        // Permanent also no-ops here for the same reason — the permanent drop
        // happens on the `.flushing + .sendFailed(permanent: true)` branch.
        let (s2, fx2) = reduce(.backoff(attempt: 4, pendingBatch: batch),
                               .sendFailed(batch: batch, permanent: true, retryAfter: nil),
                               batchLimit: 20)
        XCTAssertEqual(s2, .backoff(attempt: 4, pendingBatch: batch))
        XCTAssertTrue(fx2.isEmpty)
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
        XCTAssertEqual(s, .flushing(batch: batch, attempt: 1))
        XCTAssertEqual(fx, [.cancelTimer, .httpPost(batch: batch)])
    }

    func test_flushing_plus_flushRequested_staysFlushing() {
        let inFlight = [makeEvent("a")]
        let (s, fx) = reduce(.flushing(batch: inFlight, attempt: 2),
                             .flushRequested, batchLimit: 20)
        XCTAssertEqual(s, .flushing(batch: inFlight, attempt: 2))
        XCTAssertTrue(fx.isEmpty)
    }

    func test_backoff_plus_flushRequested_forcesImmediateRetry_advancesAttempt() {
        // User-forced retry still advances the attempt counter: this is the
        // (n+1)th try, so if it also fails the ladder continues correctly.
        let batch = [makeEvent("pending")]
        let (s, fx) = reduce(.backoff(attempt: 3, pendingBatch: batch),
                             .flushRequested, batchLimit: 20)
        XCTAssertEqual(s, .flushing(batch: batch, attempt: 4))
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
