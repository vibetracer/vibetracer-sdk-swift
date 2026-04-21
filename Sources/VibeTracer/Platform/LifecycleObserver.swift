import Foundation

public protocol LifecycleObserver: AnyObject {
    var onActivate: () -> Void { get set }
    var onBackground: () -> Void { get set }
    var onTerminate: () -> Void { get set }
    func start()
    func stop()
}

/// Fallback for platforms where no matching `canImport` branch applies.
/// All callbacks are no-ops; start/stop do nothing. Included to keep the
/// factory function total.
public final class NoopLifecycleObserver: LifecycleObserver {
    public var onActivate: () -> Void = {}
    public var onBackground: () -> Void = {}
    public var onTerminate: () -> Void = {}
    public init() {}
    public func start() {}
    public func stop() {}
}
