import XCTest
@testable import VibeTracer

final class SmokeTests: XCTestCase {
    func testModuleImports() {
        XCTAssertEqual(VibeTracer.version, "1.1.3")
    }
}
