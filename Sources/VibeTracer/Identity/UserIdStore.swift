import Foundation

/// Persists the currently-identified user id in UserDefaults.
///
/// Unlike the device id, the user id is explicitly opt-in: callers invoke
/// `identify(userId:)` when they know who the user is, and `reset()` on
/// logout. The store survives app relaunches so we can continue to attribute
/// events to the right user after a process restart.
///
/// Thread-safe because `UserDefaults` is documented as thread-safe for
/// concurrent reads/writes by Apple (Foundation). The `Sendable` conformance
/// is `@unchecked` only because `UserDefaults` is imported from Objective-C
/// and predates Swift concurrency — it doesn't declare `Sendable`, but all
/// operations on it are thread-safe. Under Swift 6 strict concurrency this
/// is the correct annotation; the previous `Sendable` (checked) form was a
/// compiler warning today and a hard error under the Swift 6 language mode.
public final class UserIdStore: @unchecked Sendable {
    private static let key = "com.vibetracer.userId"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The currently-identified user id, or nil if none has been set (or
    /// `reset()` was called since).
    public var current: String? {
        defaults.string(forKey: Self.key)
    }

    /// Stores the given user id, overwriting any prior value.
    public func identify(userId: String) {
        defaults.set(userId, forKey: Self.key)
    }

    /// Clears the stored user id.
    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
