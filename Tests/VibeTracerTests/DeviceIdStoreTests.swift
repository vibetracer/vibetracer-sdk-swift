import XCTest
@testable import VibeTracer

final class DeviceIdStoreTests: XCTestCase {
    func test_getOrCreate_returnsValid36CharUUID() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = DeviceIdStore(defaults: defaults)
        let uuid = store.getOrCreate()
        XCTAssertEqual(uuid.uuidString.count, 36)
    }

    func test_getOrCreate_isStableAcrossCallsOnSameInstance() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = DeviceIdStore(defaults: defaults)
        let first = store.getOrCreate()
        let second = store.getOrCreate()
        XCTAssertEqual(first, second)
    }

    func test_persistsAcrossInstancesBackedBySameDefaults() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = DeviceIdStore(defaults: defaults).getOrCreate()
        let second = DeviceIdStore(defaults: defaults).getOrCreate()
        XCTAssertEqual(first, second)
    }
}
