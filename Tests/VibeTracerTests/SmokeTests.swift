import Testing
@testable import VibeTracer

@Suite struct SmokeTests {
    @Test func moduleImports() {
        #expect(VibeTracer.version == "2.2.1")
    }
}
