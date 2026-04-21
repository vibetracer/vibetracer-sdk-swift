import Foundation

/// Inputs to the FSM. A `QueueSignal` is an instruction to the reducer;
/// `AnalyticsEvent` is the data model for a single analytics event. Don't confuse them.
///
/// The `permanent` flag on `sendFailed` encodes the 400/422 vs. retryable split —
/// computed at the network layer using `classify(status:)`, passed to the FSM
/// as a bool so the reducer stays pure.
///
/// ### `appBackgrounded` vs. `flushRequested`
///
/// These two signals look similar but express different intent:
///
/// - `appBackgrounded` is fired by the OS lifecycle when the app is about to be
///   suspended. Persist what we have and try to flush from `.queuing`, but do
///   NOT force a retry from `.backoff` — an in-flight backoff is already the
///   right thing to do and cutting it short burns battery trying to hit a
///   network the OS is about to take away.
/// - `flushRequested` is fired by the user calling `VibeTracer.flush()`. It
///   means "send my events NOW", which is strong enough to cancel an active
///   backoff and retry immediately.
public enum QueueSignal: Sendable {
    case track(AnalyticsEvent)
    case timerFired
    case batchFull
    case sendOk(batch: [AnalyticsEvent])
    case sendFailed(batch: [AnalyticsEvent], permanent: Bool)
    case backoffExpired
    case appBackgrounded
    case appTerminating
    case flushRequested
}
