import Foundation
import Network

/// Observes network reachability and fires `onBecameReachable` on the
/// low→high edge (offline → online). The SDK uses this as an early-wake
/// signal from the `.backoff` state: instead of sleeping the full
/// exponential ceiling (up to 60s) after a failed flush, we wake the
/// moment the interface reports `.satisfied` again.
///
/// This is an optimization on top of the timer-based backoff — the clock
/// timer remains the safety net in case `NWPathMonitor` misses an edge.
public protocol ConnectivityMonitor: AnyObject, Sendable {
    /// Called exactly once per offline→online transition. Callers assign
    /// a closure before ``start()``.
    var onBecameReachable: (() -> Void)? { get set }
    func start()
    func stop()
}

/// Production `ConnectivityMonitor` backed by `NWPathMonitor`. The monitor
/// runs on a private serial queue; the callback is invoked on that queue,
/// so subscribers should hop to their own isolation domain (e.g., wrap the
/// body in `Task { await actor.method() }`).
public final class SystemConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "xyz.vibetracer.connectivity")
    private var wasReachable = false
    public var onBecameReachable: (() -> Void)?

    public init() {}

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = path.status == .satisfied
            if reachable && !self.wasReachable {
                self.onBecameReachable?()
            }
            self.wasReachable = reachable
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}
