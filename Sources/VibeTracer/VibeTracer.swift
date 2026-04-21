import Foundation
import os
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#elseif canImport(WatchKit) && os(watchOS)
import WatchKit
#endif

/// Vibe Tracer SDK public entry point. The full surface area:
///
/// ```swift
/// VibeTracer.configure(apiKey: "vtr_live_xxx")
/// VibeTracer.track("screen_view", properties: ["name": "Home"])
/// VibeTracer.identify(userId: "user_42")
/// VibeTracer.reset()
/// await VibeTracer.flush()
/// VibeTracer.disable()   // CCPA/GDPR opt-out — persists across launches
/// VibeTracer.enable()
/// VibeTracer.version     // "1.1.2"
/// ```
///
/// Every method is safe to call from any thread. `track()` is fire-and-forget:
/// it returns immediately and enqueues the event onto ``VibeTracerCore``'s
/// internal serial mailbox, which guarantees FIFO processing even under
/// concurrent calls.
public enum VibeTracer {

    // NSLock-protected singleton holder. We deliberately avoid `@MainActor` on
    // the public surface because we don't want to force every caller of
    // `track()` into MainActor isolation; we also avoid `nonisolated(unsafe)`
    // so the type stays clean under Swift 6 strict concurrency.
    private static let lock = NSLock()
    private static var _core: VibeTracerCore?
    private static var core: VibeTracerCore? {
        get { lock.lock(); defer { lock.unlock() }; return _core }
        set { lock.lock(); _core = newValue; lock.unlock() }
    }

    private static let logger = Logger(subsystem: "xyz.vibetracer.sdk", category: "VibeTracer")

    // MARK: - configure

    /// Configures the SDK with your API key. Call once per process, typically
    /// from your app delegate's `application(_:didFinishLaunchingWithOptions:)`
    /// or equivalent.
    ///
    /// - Parameters:
    ///   - apiKey: Your Vibe Tracer publishable key (starts with `vtr_live_`
    ///     or `vtr_test_`).
    ///   - endpoint: Override for self-hosted deployments. Defaults to the
    ///     hosted API.
    ///   - debug: When `true`, events are logged to the console via
    ///     `os.Logger` instead of being POSTed to the backend. The FSM
    ///     otherwise behaves identically, so queueing/flushing semantics can
    ///     be validated locally before going live.
    public static func configure(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.vibetracer.xyz")!,
        debug: Bool = false
    ) {
        configure(apiKey: apiKey, endpoint: endpoint, debug: debug, urlSession: .shared)
    }

    /// Internal overload: allows tests (and future diagnostics tooling) to
    /// inject a custom `URLSession`. Keeping this internal avoids adding a
    /// SPI surface that production apps would be tempted to misuse.
    internal static func configure(
        apiKey: String,
        endpoint: URL,
        debug: Bool,
        urlSession: URLSession
    ) {
        let defaults = UserDefaults.standard
        let deviceId = DeviceIdStore(defaults: defaults).getOrCreate()
        let userIdStore = UserIdStore(defaults: defaults)
        let clock = SystemClock()
        let sessionTracker = SessionTracker(defaults: defaults, clock: clock)
        let queueDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeTracer/queue")
        let disk = DiskQueue(directory: queueDir)
        let network = Network(
            endpoint: endpoint, apiKey: apiKey,
            sdkVersion: Self.sdkVersionHeader(),
            session: urlSession
        )
        let lifecycle = makeLifecycleObserver()
        let connectivity = SystemConnectivityMonitor()
        let initiallyDisabled = defaults.bool(forKey: "com.vibetracer.disabled")

        lock.lock()
        if _core != nil {
            lock.unlock()
            logger.warning("VibeTracer.configure() called twice; ignoring second call")
            return
        }
        let newCore = VibeTracerCore(
            deviceId: deviceId,
            userIdStore: userIdStore,
            sessionTracker: sessionTracker,
            disk: disk,
            network: network,
            clock: clock,
            lifecycle: lifecycle,
            connectivity: connectivity,
            debug: debug,
            logger: logger,
            initiallyDisabled: initiallyDisabled
        )
        _core = newCore
        lock.unlock()

        // The mailbox buffers signals enqueued before `start()` completes, so
        // `track()` calls made immediately after `configure()` are safely
        // ordered behind the session-start synthesized inside `start()`.
        Task { await newCore.start() }
    }

    // MARK: - track

    /// Records an event. Fire-and-forget — returns immediately.
    public static func track(_ event: String, properties: [String: Any]? = nil) {
        guard let core else {
            logger.warning("VibeTracer.track() called before configure() — event dropped")
            return
        }
        Task { await core.track(event: event, properties: properties) }
    }

    // MARK: - identity

    public static func identify(userId: String) {
        guard let core else { return }
        Task { await core.identify(userId: userId) }
    }

    public static func reset() {
        guard let core else { return }
        Task { await core.reset() }
    }

    // MARK: - flush

    /// Flushes the queue now and waits for the in-flight batch to complete.
    public static func flush() async {
        guard let core else { return }
        await core.flush()
    }

    // MARK: - privacy opt-out

    /// Disable event collection. Persists across launches. No-ops all
    /// subsequent `track()` calls until `enable()` is called. Intended for
    /// consent-flow integration (e.g., call before a user accepts a GDPR
    /// consent banner).
    public static func disable() {
        UserDefaults.standard.set(true, forKey: "com.vibetracer.disabled")
        guard let core else { return }
        Task { await core.setDisabled(true) }
    }

    public static func enable() {
        UserDefaults.standard.set(false, forKey: "com.vibetracer.disabled")
        guard let core else { return }
        Task { await core.setDisabled(false) }
    }

    // MARK: - version

    public static let version = "1.1.2"

    // MARK: - internals

    /// Builds the `X-Vibetracer-SDK` header value. Format:
    /// `swift/<sdk>; <os>/<osVersion>` — helps us identify which platforms
    /// are in the field and whether a bug is OS-specific.
    private static func sdkVersionHeader() -> String {
        let osName: String
        #if os(iOS)
        osName = "iOS"
        #elseif os(macOS)
        osName = "macOS"
        #elseif os(tvOS)
        osName = "tvOS"
        #elseif os(watchOS)
        osName = "watchOS"
        #elseif os(visionOS)
        osName = "visionOS"
        #else
        osName = "unknown"
        #endif
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return "swift/\(version); \(osName)/\(osVersion)"
    }

    #if DEBUG
    /// Test hook: tears down the singleton so back-to-back
    /// `configure()` calls in a single test process start clean.
    internal static func resetForTesting() {
        lock.lock(); _core = nil; lock.unlock()
    }
    #endif
}

/// Selects the lifecycle observer matching the host platform. Pulled out of
/// `VibeTracer.configure` so the `#if canImport` cascade lives in one place.
private func makeLifecycleObserver() -> LifecycleObserver {
    #if canImport(UIKit) && !os(watchOS)
    return UIKitLifecycleObserver()
    #elseif canImport(AppKit)
    return AppKitLifecycleObserver()
    #elseif canImport(WatchKit) && os(watchOS)
    return WatchKitLifecycleObserver()
    #else
    return NoopLifecycleObserver()
    #endif
}
