#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

public final class UIKitLifecycleObserver: LifecycleObserver {
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
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.onActivate() })
        observers.append(notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.onBackground() })
        observers.append(notificationCenter.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.onTerminate() })
    }

    public func stop() {
        for o in observers { notificationCenter.removeObserver(o) }
        observers.removeAll()
    }

    deinit { stop() }
}
#endif
