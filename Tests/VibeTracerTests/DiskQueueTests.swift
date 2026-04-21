import XCTest
@testable import VibeTracer

final class DiskQueueTests: XCTestCase {
    var tempDir: URL!
    var queue: DiskQueue!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        queue = DiskQueue(directory: tempDir, maxEvents: 100)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_persist_thenLoad_roundtrip() async throws {
        let e = AnalyticsEvent(event: "x", deviceId: "d", userId: nil, sessionId: "s")
        try await queue.persist([e])
        let loaded = try await queue.loadAll()
        XCTAssertEqual(loaded, [e])
    }

    func test_remove_byId() async throws {
        let a = AnalyticsEvent(event: "a", deviceId: "d", userId: nil, sessionId: "s",
                               timestamp: Date(timeIntervalSince1970: 1))
        let b = AnalyticsEvent(event: "b", deviceId: "d", userId: nil, sessionId: "s",
                               timestamp: Date(timeIntervalSince1970: 2))
        try await queue.persist([a, b])
        try await queue.remove(ids: [a.clientEventId])
        let loaded = try await queue.loadAll()
        XCTAssertEqual(loaded, [b])
    }

    func test_corruptFile_isSkipped_onLoad() async throws {
        let bad = tempDir.appendingPathComponent("20200101T000000.000Z-bad.json")
        try "not valid json { garbage".write(to: bad, atomically: true, encoding: .utf8)
        let good = AnalyticsEvent(event: "ok", deviceId: "d", userId: nil, sessionId: "s")
        try await queue.persist([good])
        let loaded = try await queue.loadAll()
        XCTAssertEqual(loaded, [good])
    }

    func test_exceedMaxEvents_evictsOldest() async throws {
        queue = DiskQueue(directory: tempDir, maxEvents: 3)
        for i in 0..<5 {
            let e = AnalyticsEvent(event: "e\(i)", deviceId: "d", userId: nil, sessionId: "s",
                                   timestamp: Date(timeIntervalSince1970: TimeInterval(i)))
            try await queue.persist([e])
        }
        let loaded = try await queue.loadAll()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.map { $0.event }, ["e2", "e3", "e4"])
    }
}
