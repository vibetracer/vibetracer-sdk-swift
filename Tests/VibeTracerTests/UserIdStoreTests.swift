import XCTest
@testable import VibeTracer

final class UserIdStoreTests: XCTestCase {
    func test_freshStore_currentIsNil() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UserIdStore(defaults: defaults)
        XCTAssertNil(store.current)
    }

    func test_identify_setsCurrent() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UserIdStore(defaults: defaults)
        store.identify(userId: "abc")
        XCTAssertEqual(store.current, "abc")
    }

    func test_reset_clearsCurrent() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UserIdStore(defaults: defaults)
        store.identify(userId: "abc")
        store.reset()
        XCTAssertNil(store.current)
    }

    func test_identify_persistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        UserIdStore(defaults: defaults).identify(userId: "abc")
        let reloaded = UserIdStore(defaults: defaults)
        XCTAssertEqual(reloaded.current, "abc")
    }
}
