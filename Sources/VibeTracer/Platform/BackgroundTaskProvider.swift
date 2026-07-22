import Foundation

/// Opaque handle for one background-execution assertion. Returned by
/// ``BackgroundTaskProvider/begin(name:)`` and passed back to
/// ``BackgroundTaskProvider/end(_:)`` to release it.
public struct BackgroundTaskToken: Sendable, Hashable {
    /// Opaque to callers; only the provider that minted it reads it (to key its
    /// internal identifier map). A fresh token is unique per `begin`.
    fileprivate let id: UUID
    public init() { self.id = UUID() }
}

/// Bridges a platform background-execution assertion so an in-flight flush and
/// its on-disk cleanup can finish before the OS suspends the process.
///
/// ### Why this exists
///
/// On iOS the delivery pipeline is: `POST → server commits (202) → .sendOk →
/// removeFromDisk`. When the app is backgrounded, iOS starts a suspension
/// countdown. If it suspends *after* the server has committed a batch but
/// *before* `removeFromDisk` runs, the events survive on disk and re-post on the
/// next launch — the same `clientEventId` gets ingested again. Holding a
/// background-task assertion across the background flush closes that window for
/// the common case.
///
/// ### The load-bearing contract
///
/// ``begin(name:)`` MUST be invoked while the process is still foreground-
/// eligible — i.e. **synchronously** inside the `didEnterBackground`
/// notification, before any `await`. Deferring it onto an actor hop can miss the
/// window and the OS may suspend first. ``end(_:)`` is called once the guarded
/// work settles; it is safe to call from any thread and is idempotent per token
/// (ending an already-ended or expired token is a no-op).
public protocol BackgroundTaskProvider: Sendable {
    func begin(name: String) -> BackgroundTaskToken
    func end(_ token: BackgroundTaskToken)
}

/// Default provider for platforms without a background-task assertion (macOS,
/// watchOS, Linux) and for tests. Hands back a token and does nothing — the
/// flush still runs, just without a suspension guard the platform doesn't offer.
public struct NoopBackgroundTaskProvider: BackgroundTaskProvider {
    public init() {}
    public func begin(name: String) -> BackgroundTaskToken { BackgroundTaskToken() }
    public func end(_ token: BackgroundTaskToken) {}
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Wraps `UIApplication.beginBackgroundTask` / `endBackgroundTask`. All access
/// to `UIApplication` and the token map happens on the main actor: `begin` is
/// called synchronously from the (main-thread) lifecycle notification, and
/// `end` hops to main when invoked from a background thread. The OS expiration
/// handler ends the assertion itself, so a task is never force-killed.
public final class UIKitBackgroundTaskProvider: BackgroundTaskProvider, @unchecked Sendable {

    /// Main-actor-only. Maps our opaque token to the live UIKit identifier.
    private var tasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    public init() {}

    public func begin(name: String) -> BackgroundTaskToken {
        let token = BackgroundTaskToken()
        // `didEnterBackground` is delivered on the main thread while the app is
        // still foreground-eligible, so we are safely main-isolated here.
        MainActor.assumeIsolated {
            var identifier: UIBackgroundTaskIdentifier = .invalid
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                // Time budget ran out before the flush finished — release now
                // so iOS doesn't force-kill the assertion (which flags the app).
                self?.endOnMain(token)
            }
            tasks[token.id] = identifier
        }
        return token
    }

    public func end(_ token: BackgroundTaskToken) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { endOnMain(token) }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.endOnMain(token) }
            }
        }
    }

    @MainActor
    private func endOnMain(_ token: BackgroundTaskToken) {
        guard let identifier = tasks.removeValue(forKey: token.id),
              identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
#endif
