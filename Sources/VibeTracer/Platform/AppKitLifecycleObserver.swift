#if canImport(AppKit)
import Foundation
import AppKit

public final class AppKitLifecycleObserver: LifecycleObserver {
    public var onActivate: () -> Void = {}
    public var onBackground: () -> Void = {}
    public var onTerminate: () -> Void = {}

    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    public func start() {
        observers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.onActivate() })
        observers.append(notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.onBackground() })
        observers.append(notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.onTerminate() })
    }

    public func stop() {
        for o in observers { notificationCenter.removeObserver(o) }
        observers.removeAll()
    }

    deinit { stop() }
}
#endif
