import Foundation

/// Translates a ``SessionRolloverResult`` into the analytics events it implies.
///
/// Extracted from `VibeTracerCore` so the mapping between "what just happened
/// in the session tracker" and "what events should ship over the wire" can be
/// unit-tested without booting the actor / `TestClock` / mock network. The
/// rule encoded here is the entire v1.1.1 fix for spurious `$session_start`
/// emission — keep it narrow, keep it pure.
///
/// Invariants:
///   - `$session_end` is emitted iff `rollover.expired != nil`.
///   - `$session_start` is emitted iff `rollover.wasMinted`.
///   - A reused session (`expired == nil && !wasMinted`) produces zero events.
///   - When both happen in the same rollover (idle expiry + fresh mint), the
///     end event precedes the start event — mirrors the temporal order.
struct SessionEmitter {
    let deviceId: UUID
    let userIdStore: UserIdStore
    let clock: Clock

    /// Returns the analytics events that should be enqueued for this rollover.
    /// Empty array if the session is being reused (no minting, no prior expiry).
    func eventsFor(rollover: SessionRolloverResult) -> [AnalyticsEvent] {
        var events: [AnalyticsEvent] = []
        if let expired = rollover.expired {
            events.append(AnalyticsEvent(
                event: "$session_end",
                deviceId: deviceId.uuidString,
                userId: userIdStore.current,
                sessionId: expired.sessionId.uuidString,
                timestamp: expired.lastActivityAt,
                properties: [:]
            ))
        }
        if rollover.wasMinted {
            events.append(AnalyticsEvent(
                event: "$session_start",
                deviceId: deviceId.uuidString,
                userId: userIdStore.current,
                sessionId: rollover.currentSessionId.uuidString,
                timestamp: clock.now(),
                properties: [:]
            ))
        }
        return events
    }
}
