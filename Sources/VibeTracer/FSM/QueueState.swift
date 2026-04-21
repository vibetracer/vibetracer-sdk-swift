import Foundation

/// Current state of the offline-capable event queue.
/// Transitions happen ONLY through `reduce(_:_:batchLimit:currentBatch:)`.
public enum QueueState: Equatable, Sendable {
    case empty
    case queuing
    case flushing(batch: [AnalyticsEvent])
    case backoff(attempt: Int, pendingBatch: [AnalyticsEvent])
}
