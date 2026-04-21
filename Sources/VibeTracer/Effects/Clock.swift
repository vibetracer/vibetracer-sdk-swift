import Foundation

/// Abstracts time + timers so the actor doesn't depend on DispatchQueue directly,
/// and tests can advance time deterministically.
public protocol Clock: AnyObject, Sendable {
    func now() -> Date
    /// Schedule `block` to run after `duration`. Returns an opaque handle that
    /// can be used to cancel via `cancel`.
    func scheduleAfter(_ duration: Duration, _ block: @escaping @Sendable () -> Void) -> ClockHandle
    func cancel(_ handle: ClockHandle)
}

public struct ClockHandle: Sendable, Hashable {
    let id: UUID
}

public final class SystemClock: Clock, @unchecked Sendable {
    private struct Scheduled { let handle: ClockHandle; let task: Task<Void, Never> }
    private let lock = NSLock()
    private var scheduled: [UUID: Scheduled] = [:]

    public init() {}
    public func now() -> Date { Date() }
    public func scheduleAfter(_ duration: Duration, _ block: @escaping @Sendable () -> Void) -> ClockHandle {
        let handle = ClockHandle(id: UUID())
        let task = Task { [weak self] in
            try? await Task.sleep(for: duration)
            if Task.isCancelled { return }
            block()
            self?.remove(handle)
        }
        lock.lock(); scheduled[handle.id] = Scheduled(handle: handle, task: task); lock.unlock()
        return handle
    }
    public func cancel(_ handle: ClockHandle) {
        lock.lock()
        let s = scheduled.removeValue(forKey: handle.id)
        lock.unlock()
        s?.task.cancel()
    }
    private func remove(_ h: ClockHandle) {
        lock.lock(); scheduled.removeValue(forKey: h.id); lock.unlock()
    }
}
