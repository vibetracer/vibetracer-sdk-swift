import Foundation

/// Inputs to the FSM. A `QueueSignal` is an instruction to the reducer;
/// `AnalyticsEvent` is the data model for a single analytics event. Don't confuse them.
///
/// The `permanent` flag on `sendFailed` encodes the 400/422 vs. retryable split —
/// computed at the network layer using `classify(status:)`, passed to the FSM
/// as a bool so the reducer stays pure.
public enum QueueSignal: Sendable {
    case track(AnalyticsEvent)
    case timerFired
    case batchFull
    case sendOk(batch: [AnalyticsEvent])
    case sendFailed(batch: [AnalyticsEvent], permanent: Bool)
    case backoffExpired
    case appBackgrounded
    case appTerminating
}
