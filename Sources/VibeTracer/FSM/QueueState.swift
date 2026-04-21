import Foundation

/// Current state of the offline-capable event queue.
/// Transitions happen ONLY through `reduce(_:_:batchLimit:currentBatch:)`.
///
/// ### Attempt-counter invariant
///
/// `.flushing(batch:attempt:)` and `.backoff(attempt:pendingBatch:)` share
/// the same meaning for `attempt`: the 1-based ordinal of the current send
/// attempt for this batch.
///
/// - `.flushing(attempt: n)` = attempt number `n` is currently in flight.
/// - `.backoff(attempt: n)` = attempt `n` failed; waiting
///   `computeBackoff(attempt: n)` (or server `Retry-After`) before trying
///   attempt `n + 1`.
///
/// When a retry begins after the backoff expires, the FSM transitions
/// `.backoff(n) → .flushing(attempt: n + 1)`. Successes return to `.empty`
/// or `.queuing`, discarding the attempt counter so the next fresh flush
/// restarts at 1.
///
/// This invariant is load-bearing: without `attempt` living in `.flushing`,
/// the counter would reset on every `.backoff → .flushing → .sendFailed`
/// round-trip and the exp-backoff ladder would never climb past 1s.
public enum QueueState: Equatable, Sendable {
    case empty
    case queuing
    case flushing(batch: [AnalyticsEvent], attempt: Int)
    case backoff(attempt: Int, pendingBatch: [AnalyticsEvent])
}
