import Foundation

/// Side effects emitted by the reducer. The runner executes them;
/// tests just assert they were emitted.
public enum QueueEffect: Equatable, Sendable {
    case scheduleTimer(after: Duration)
    case cancelTimer
    case persistToDisk(events: [AnalyticsEvent])
    case removeFromDisk(eventIds: [UUID])
    case httpPost(batch: [AnalyticsEvent])
    case localLog(AnalyticsEvent)
    case batchDropped(reason: String, count: Int)
}
