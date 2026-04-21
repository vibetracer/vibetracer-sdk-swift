import XCTest
@testable import VibeTracer

final class SmokeTests: XCTestCase {
    func testModuleImports() {
        XCTAssertEqual(VibeTracer.version, "2.1.0")
    }
}
