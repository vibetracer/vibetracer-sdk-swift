import Testing
import Foundation
import os
@testable import VibeTracer

/// The background flush must run under a background-execution assertion so iOS
/// can't suspend the process between "server committed the batch" and
/// "removeFromDisk cleared it locally" — the window that re-posts the same
/// `clientEventId` on the next launch.
///
/// Serialized: uses debug mode (no network) so it doesn't touch the shared
/// `MockURLProtocol.handler`, but keeping the suite serial avoids surprises if
/// that changes.
@Suite(.serialized)
struct BackgroundFlushAssertionTests {

    final class FakeLifecycle: LifecycleObserver, @unchecked Sendable {
        var onActivate: () -> Void = {}
        var onBackground: () -> Void = {}
        var onTerminate: () -> Void = {}
        func start() {}
        func stop() {}
    }

    /// Records begin/end counts and lets a test await a target end count
    /// deterministically (the real end fires from a detached Task after the
    /// flush settles — no sleeps).
    final class FakeBackgroundTaskProvider: BackgroundTaskProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _beginCount = 0
        private var _endCount = 0
        private var waiters: [(target: Int, cont: CheckedContinuation<Void, Never>)] = []

        var beginCount: Int { lock.lock(); defer { lock.unlock() }; return _beginCount }
        var endCount: Int { lock.lock(); defer { lock.unlock() }; return _endCount }

        func begin(name: String) -> BackgroundTaskToken {
            lock.lock(); _beginCount += 1; lock.unlock()
            return BackgroundTaskToken()
        }

        func end(_ token: BackgroundTaskToken) {
            lock.lock()
            _endCount += 1
            let ready = waiters.filter { $0.target <= _endCount }
            waiters.removeAll { $0.target <= _endCount }
            lock.unlock()
            for w in ready { w.cont.resume() }
        }

        func waitForEndCount(_ target: Int) async {
            await withCheckedContinuation { cont in
                lock.lock()
                if _endCount >= target { lock.unlock(); cont.resume(); return }
                waiters.append((target, cont))
                lock.unlock()
            }
        }
    }

    private func makeCore(
        provider: BackgroundTaskProvider,
        lifecycle: LifecycleObserver
    ) async -> (VibeTracerCore, DiskQueue) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-bgassert-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let disk = DiskQueue(directory: dir)
        let clock = TestClock(start: Date(timeIntervalSinceReferenceDate: 1_000_000))
        // debug: true → httpPost is rewritten to a synthesized sendOk, so the
        // flush drains disk without any real network.
        let network = Network(
            endpoint: URL(string: "https://example.invalid")!,
            apiKey: "vtr_test_x", sdkVersion: "swift/test"
        )
        let sessionTracker = SessionTracker(defaults: defaults, clock: clock)
        let userIdStore = UserIdStore(defaults: defaults)
        let logger = Logger(subsystem: "xyz.vibetracer.test", category: "bgassert")
        let core = VibeTracerCore(
            deviceId: UUID(),
            userIdStore: userIdStore,
            sessionTracker: sessionTracker,
            disk: disk,
            network: network,
            clock: clock,
            lifecycle: lifecycle,
            debug: true,
            logger: logger,
            backgroundTasks: provider
        )
        return (core, disk)
    }

    @Test
    func backgroundFlush_takesAssertionSynchronously_andReleasesAfterQueueDrains() async throws {
        let provider = FakeBackgroundTaskProvider()
        let lifecycle = FakeLifecycle()
        let (core, disk) = await makeCore(provider: provider, lifecycle: lifecycle)
        await core.start()
        await core._waitForIdle()

        await core.track(event: "checkout", properties: nil)
        await core._waitForIdle()
        #expect(try await disk.count() >= 1)   // queued, not yet flushed

        // App backgrounds. The assertion must be taken synchronously here,
        // before any async flush work — otherwise iOS could suspend first.
        lifecycle.onBackground()
        try #require(provider.beginCount == 1)

        // ...and released only once the queue has fully drained.
        await provider.waitForEndCount(1)
        #expect(provider.endCount == 1)
        #expect(try await disk.count() == 0)
    }
}
