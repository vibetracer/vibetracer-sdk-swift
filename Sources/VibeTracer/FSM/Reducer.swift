import Foundation

/// Pure transition function. Never performs IO. Every side effect is named in
/// the returned `[QueueEffect]` array and executed by a separate runner.
///
/// - Parameters:
///   - state: current state.
///   - event: the input signal driving the transition.
///   - batchLimit: max events per flush batch (usually 20).
///   - currentBatch: the queue's currently-persisted events, up to `batchLimit`.
///     Passed in because the FSM itself doesn't own the queue — the runner does.
///     The caller reads disk to populate.
public func reduce(
    _ state: QueueState,
    _ event: QueueSignal,
    batchLimit: Int,
    currentBatch: [AnalyticsEvent] = []
) -> (QueueState, [QueueEffect]) {
    switch (state, event) {

    // MARK: — empty
    case (.empty, .track(let e)):
        return (.queuing, [.persistToDisk(events: [e]), .scheduleTimer(after: .seconds(5))])
    case (.empty, .timerFired),
         (.empty, .batchFull),
         (.empty, .backoffExpired),
         (.empty, .sendOk),
         (.empty, .sendFailed),
         (.empty, .appBackgrounded),
         (.empty, .appTerminating),
         (.empty, .flushRequested):
        // Nothing in flight and nothing queued — every non-track signal is a no-op.
        // Explicit cases rather than a catchall so the exhaustiveness check catches
        // new signals at compile time.
        return (.empty, [])

    // MARK: — queuing
    case (.queuing, .track(let e)):
        // Timer already ticking from the empty→queuing transition; don't re-arm.
        return (.queuing, [.persistToDisk(events: [e])])
    case (.queuing, .timerFired):
        if currentBatch.isEmpty { return (.empty, []) }
        return (.flushing(batch: currentBatch), [.httpPost(batch: currentBatch)])
    case (.queuing, .batchFull):
        return (.flushing(batch: currentBatch), [.cancelTimer, .httpPost(batch: currentBatch)])
    case (.queuing, .appBackgrounded):
        if currentBatch.isEmpty { return (.queuing, []) }
        return (.flushing(batch: currentBatch), [.cancelTimer, .httpPost(batch: currentBatch)])
    case (.queuing, .flushRequested):
        // User-initiated flush from `VibeTracer.flush()`. Same shape as
        // appBackgrounded from .queuing — flush now if there's anything to send.
        if currentBatch.isEmpty { return (.queuing, []) }
        return (.flushing(batch: currentBatch), [.cancelTimer, .httpPost(batch: currentBatch)])
    case (.queuing, .appTerminating):
        return (.queuing, [])   // persisted already; next launch resumes
    case (.queuing, .sendOk),
         (.queuing, .sendFailed),
         (.queuing, .backoffExpired):
        // Stale callbacks / spurious signals; no-op rather than corrupt state.
        return (.queuing, [])

    // MARK: — flushing
    case (.flushing(let inFlight), .sendOk(let batch)):
        // Identity equality, not count equality — the plan's original
        // `inFlight.count == batch.count` was a tautology. Use set equality
        // on clientEventId so a misrouted ack self-heals instead of silently
        // removing the wrong disk entries.
        let inFlightIds = Set(inFlight.map(\.clientEventId))
        let ackedIds = Set(batch.map(\.clientEventId))
        guard inFlightIds == ackedIds else {
            // Stall recovery: flip to .queuing so the runner re-evaluates on the
            // next signal. No removeFromDisk (ids mismatch), no scheduleTimer
            // (caller re-arms on next track/flush).
            return (.queuing, [])
        }
        let ids = batch.map(\.clientEventId)
        if currentBatch.isEmpty {
            return (.empty, [.removeFromDisk(eventIds: ids)])
        }
        return (.queuing, [
            .removeFromDisk(eventIds: ids),
            .scheduleTimer(after: .seconds(5)),
        ])

    case (.flushing(let inFlight), .sendFailed(let batch, let permanent)):
        // Same identity guard — a mismatched failed callback is stall-recovered.
        let inFlightIds = Set(inFlight.map(\.clientEventId))
        let failedIds = Set(batch.map(\.clientEventId))
        guard inFlightIds == failedIds else {
            return (.queuing, [])
        }
        if permanent {
            let ids = batch.map(\.clientEventId)
            return (.empty, [
                .removeFromDisk(eventIds: ids),
                .batchDropped(reason: "permanent_client_error", count: batch.count),
            ])
        } else {
            let attempt = 1
            return (.backoff(attempt: attempt, pendingBatch: batch),
                    [.scheduleTimer(after: computeBackoff(attempt: attempt))])
        }

    case (.flushing, .track(let e)):
        // Arrives while a flush is in-flight; persist so we pick it up after.
        return (state, [.persistToDisk(events: [e])])
    case (.flushing, .appBackgrounded),
         (.flushing, .flushRequested):
        return (state, [])   // flush already running; let it complete
    case (.flushing, .timerFired),
         (.flushing, .batchFull),
         (.flushing, .backoffExpired),
         (.flushing, .appTerminating):
        return (state, [])

    // MARK: — backoff
    case (.backoff(_, let batch), .backoffExpired):
        return (.flushing(batch: batch), [.httpPost(batch: batch)])
    case (.backoff(let n, let b), .sendFailed(_, permanent: false)):
        let next = n + 1
        return (.backoff(attempt: next, pendingBatch: b),
                [.scheduleTimer(after: computeBackoff(attempt: next))])
    case (.backoff(_, let b), .sendFailed(_, permanent: true)):
        // Drop the pending batch and reset; don't keep it queued indefinitely.
        let ids = b.map(\.clientEventId)
        return (.empty, [
            .removeFromDisk(eventIds: ids),
            .batchDropped(reason: "permanent_client_error", count: b.count),
        ])
    case (.backoff, .track(let e)):
        return (state, [.persistToDisk(events: [e])])
    case (.backoff(_, let batch), .flushRequested):
        // User-initiated flush overrides the backoff timer — cancel it and
        // retry the pending batch immediately. This is intentionally more
        // aggressive than appBackgrounded, which respects the backoff.
        return (.flushing(batch: batch), [.cancelTimer, .httpPost(batch: batch)])
    case (.backoff, .timerFired),
         (.backoff, .batchFull),
         (.backoff, .sendOk),
         (.backoff, .appBackgrounded),
         (.backoff, .appTerminating):
        // Keep state; timers/batchFull are ignored during backoff, appTerminating
        // leaves the pending batch on disk for the next launch to resume.
        return (state, [])
    }
}

/// Exponential backoff with ±20% random jitter; capped at 60s.
/// Pure except for the random jitter — deterministic tests pass their own RNG
/// via `computeBackoff(attempt:rng:)`.
public func computeBackoff(
    attempt: Int,
    rng: @autoclosure () -> Double = Double.random(in: 0.8...1.2)
) -> Duration {
    let ladder: [Int] = [1, 2, 4, 8, 16, 32, 60]
    let baseSec = ladder[min(max(attempt - 1, 0), ladder.count - 1)]
    let jittered = Double(baseSec) * rng()
    return .milliseconds(Int(jittered * 1000))
}
