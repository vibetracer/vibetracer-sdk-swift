import Foundation

/// Mandatory default properties merged into every tracked event. Populated
/// once at `configure()` — every field is immutable for the process lifetime
/// (app version is fixed per build, OS version doesn't change mid-run,
/// simulator/Catalyst status are compile-time, build type is decided at the
/// App Store / TestFlight / dev-signing boundary before launch).
///
/// Wire format: each field is emitted under a `$`-prefixed key to match the
/// existing session-event prefix convention (`$session_start` etc.) and to
/// keep system properties visually distinct from user-supplied ones.
///
/// ### Key contract
///
/// - `$app_version` — `CFBundleShortVersionString` (e.g. "1.4.2")
/// - `$app_build`   — `CFBundleVersion` (e.g. "842")
/// - `$build_type`  — one of `debug`, `testflight`, `appstore`, `development`
/// - `$device_type` — one of `simulator`, `mac_catalyst`, `ios_on_mac`, `mac`, `device`
/// - `$os_name`     — `iOS`, `macOS`, `tvOS`, `watchOS`, `visionOS`
/// - `$os_version`  — dotted `major.minor.patch` from `ProcessInfo`
///
/// Missing Info.plist keys surface as `"unknown"` rather than being omitted,
/// so downstream analytics queries don't need to special-case nullability.
public struct DeviceContext: Equatable, Sendable {
    public let appVersion: String
    public let appBuild: String
    public let buildType: String
    public let deviceType: String
    public let osName: String
    public let osVersion: String

    public init(
        appVersion: String,
        appBuild: String,
        buildType: String,
        deviceType: String,
        osName: String,
        osVersion: String
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.buildType = buildType
        self.deviceType = deviceType
        self.osName = osName
        self.osVersion = osVersion
    }

    /// Wire-format dictionary with `$`-prefixed keys. Stable for the process.
    public var properties: [String: String] {
        [
            "$app_version": appVersion,
            "$app_build": appBuild,
            "$build_type": buildType,
            "$device_type": deviceType,
            "$os_name": osName,
            "$os_version": osVersion,
        ]
    }

    /// The six `$`-prefixed keys this context owns. `VibeTracerCore.track`
    /// uses this set to detect user-supplied properties that would shadow a
    /// system key.
    public static let reservedKeys: Set<String> = [
        "$app_version", "$app_build", "$build_type",
        "$device_type", "$os_name", "$os_version",
    ]

    /// Reads the current process's context. Call once at `configure()`.
    public static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> DeviceContext {
        DeviceContext(
            appVersion: readBundleString(bundle, key: "CFBundleShortVersionString"),
            appBuild: readBundleString(bundle, key: "CFBundleVersion"),
            buildType: detectBuildType(bundle: bundle),
            deviceType: detectDeviceType(processInfo: processInfo),
            osName: detectOSName(),
            osVersion: formatOSVersion(processInfo.operatingSystemVersion)
        )
    }

    private static func readBundleString(_ bundle: Bundle, key: String) -> String {
        guard let v = bundle.object(forInfoDictionaryKey: key) as? String, !v.isEmpty else {
            return "unknown"
        }
        return v
    }

    /// Distinguishes debug builds, TestFlight, App Store, and dev-signed
    /// builds. `#if DEBUG` catches Xcode-run and debug-configured builds; the
    /// receipt-URL filename is Apple's canonical signal for TestFlight
    /// (`sandboxReceipt`) vs App Store (`receipt`). Missing receipt on a
    /// release build indicates enterprise, ad-hoc, or direct-distributed
    /// (non-App-Store) macOS — labelled `development` so it's grouped with
    /// other non-production signals.
    private static func detectBuildType(bundle: Bundle) -> String {
        #if DEBUG
        return "debug"
        #else
        guard let receiptURL = bundle.appStoreReceiptURL else {
            return "development"
        }
        if receiptURL.lastPathComponent == "sandboxReceipt" {
            return "testflight"
        }
        // Receipt present and not sandbox → App Store distribution. We check
        // existence on disk as a sanity guard: a non-sandbox path that
        // doesn't exist indicates the app was built for the App Store but
        // is being side-loaded without a receipt, which is effectively a
        // development build.
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            return "appstore"
        }
        return "development"
        #endif
    }

    /// Simulator and Catalyst are compile-time (`targetEnvironment`).
    /// `isiOSAppOnMac` is a runtime check on Apple Silicon Macs running an
    /// unmodified iOS app. macOS-native builds are `mac`; everything else
    /// (iOS device, tvOS, watchOS, visionOS) is `device`.
    private static func detectDeviceType(processInfo: ProcessInfo) -> String {
        #if targetEnvironment(simulator)
        return "simulator"
        #elseif targetEnvironment(macCatalyst)
        return "mac_catalyst"
        #elseif os(macOS)
        return "mac"
        #else
        if #available(iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
            if processInfo.isiOSAppOnMac { return "ios_on_mac" }
        }
        return "device"
        #endif
    }

    private static func detectOSName() -> String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "unknown"
        #endif
    }

    private static func formatOSVersion(_ v: OperatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
