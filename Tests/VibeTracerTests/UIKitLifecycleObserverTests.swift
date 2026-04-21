#if canImport(UIKit) && !os(watchOS)
import XCTest
import UIKit
@testable import VibeTracer

final class UIKitLifecycleObserverTests: XCTestCase {
    func test_didBecomeActive_firesOnActivate_once() {
        let nc = NotificationCenter()
        let observer = UIKitLifecycleObserver(notificationCenter: nc)
        var activateCount = 0
        observer.onActivate = { activateCount += 1 }
        observer.start()

        nc.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(activateCount, 1)
    }

    func test_stop_removesObservers() {
        let nc = NotificationCenter()
        let observer = UIKitLifecycleObserver(notificationCenter: nc)
        var activateCount = 0
        observer.onActivate = { activateCount += 1 }
        observer.start()
        observer.stop()

        nc.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(activateCount, 0)
    }
}
#endif
