@testable import VibeTracer
import Foundation

/// Deterministic clock for tests. `advance(by:)` runs any expired blocks.
final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var scheduled: [(handle: ClockHandle, fires: Date, block: () -> Void)] = []

    init(start: Date = Date(timeIntervalSince1970: 0)) { self.current = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func scheduleAfter(_ duration: Duration, _ block: @escaping @Sendable () -> Void) -> ClockHandle {
        let h = ClockHandle(id: UUID())
        lock.lock()
        let fires = current.addingTimeInterval(duration.seconds)
        scheduled.append((h, fires, block))
        lock.unlock()
        return h
    }
    func cancel(_ handle: ClockHandle) {
        lock.lock(); scheduled.removeAll { $0.handle == handle }; lock.unlock()
    }
    func advance(by duration: Duration) {
        lock.lock()
        current = current.addingTimeInterval(duration.seconds)
        let due = scheduled.filter { $0.fires <= current }
        scheduled.removeAll { $0.fires <= current }
        lock.unlock()
        for d in due { d.block() }
    }
}

private extension Duration {
    var seconds: TimeInterval {
        // Duration.components returns a tuple labeled (seconds, attoseconds).
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) * 1e-18
    }
}
