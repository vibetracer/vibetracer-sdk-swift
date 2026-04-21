import XCTest
@testable import VibeTracer

final class TestClockTests: XCTestCase {
    func test_advance_firesBlock() {
        let clock = TestClock()
        var fired = 0
        _ = clock.scheduleAfter(.seconds(5)) { fired += 1 }
        clock.advance(by: .seconds(4))
        XCTAssertEqual(fired, 0)
        clock.advance(by: .seconds(1))
        XCTAssertEqual(fired, 1)
    }

    func test_cancel_preventsFire() {
        let clock = TestClock()
        var fired = 0
        let h = clock.scheduleAfter(.seconds(5)) { fired += 1 }
        clock.cancel(h)
        clock.advance(by: .seconds(10))
        XCTAssertEqual(fired, 0)
    }
}
