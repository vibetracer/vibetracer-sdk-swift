import Foundation

/// Persists a stable per-install device identifier in UserDefaults.
///
/// The identifier is minted lazily on first access and survives app relaunches.
/// It is cleared only when the user deletes the app (or the UserDefaults suite
/// is reset), which matches the semantics most analytics backends expect from
/// a "device id".
public final class DeviceIdStore: Sendable {
    private static let key = "com.vibetracer.deviceId"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the stored device id, minting and persisting a new one if none
    /// exists or the stored value is malformed.
    public func getOrCreate() -> UUID {
        if let raw = defaults.string(forKey: Self.key), let uuid = UUID(uuidString: raw) {
            return uuid
        }
        let new = UUID()
        defaults.set(new.uuidString, forKey: Self.key)
        return new
    }
}
