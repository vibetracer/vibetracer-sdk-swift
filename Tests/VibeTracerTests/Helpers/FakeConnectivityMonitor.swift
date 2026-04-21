import Foundation
@testable import VibeTracer

/// Test double for `ConnectivityMonitor`. Tests call ``simulateReachable()``
/// to mimic an offline→online edge without touching the real
/// `NWPathMonitor`.
final class FakeConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {
    var onBecameReachable: (() -> Void)?
    private(set) var started = false
    private(set) var stopped = false

    func start() { started = true }
    func stop() { stopped = true }

    /// Fire the reachability callback as if the interface just came back.
    func simulateReachable() { onBecameReachable?() }
}
