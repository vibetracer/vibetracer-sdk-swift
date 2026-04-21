import XCTest
@testable import VibeTracer

final class DeviceContextTests: XCTestCase {

    func test_properties_containsAllSixKeys() {
        let ctx = DeviceContext(
            appVersion: "1.2.3",
            appBuild: "42",
            buildType: "appstore",
            deviceType: "device",
            osName: "iOS",
            osVersion: "17.0.0"
        )
        let props = ctx.properties
        XCTAssertEqual(props["$app_version"], "1.2.3")
        XCTAssertEqual(props["$app_build"], "42")
        XCTAssertEqual(props["$build_type"], "appstore")
        XCTAssertEqual(props["$device_type"], "device")
        XCTAssertEqual(props["$os_name"], "iOS")
        XCTAssertEqual(props["$os_version"], "17.0.0")
        XCTAssertEqual(Set(props.keys), DeviceContext.reservedKeys)
    }

    func test_current_producesPlausibleValues() {
        let ctx = DeviceContext.current()

        // OS name is one of the known platforms (not "unknown" when the SDK
        // is compiled for a real platform — our CI always is).
        XCTAssertTrue(
            ["iOS", "macOS", "tvOS", "watchOS", "visionOS"].contains(ctx.osName),
            "unexpected osName \(ctx.osName)"
        )

        // Version is dotted numeric.
        XCTAssertTrue(ctx.osVersion.contains("."), "osVersion not dotted: \(ctx.osVersion)")

        // Build type is one of the known labels.
        XCTAssertTrue(
            ["debug", "testflight", "appstore", "development"].contains(ctx.buildType),
            "unexpected buildType \(ctx.buildType)"
        )

        // Device type is one of the known labels.
        XCTAssertTrue(
            ["simulator", "mac_catalyst", "ios_on_mac", "mac", "device"].contains(ctx.deviceType),
            "unexpected deviceType \(ctx.deviceType)"
        )

        // `swift test` runs under a debug configuration, so `#if DEBUG` is
        // set — `current()` must report "debug".
        XCTAssertEqual(ctx.buildType, "debug")

        // `swift test` on macOS runs as a macOS-native binary, and on CI under
        // Xcode/simulator runs under the simulator environment. Either way,
        // deviceType should not be a raw-iOS-device label in a test process.
        #if os(macOS) && !targetEnvironment(macCatalyst)
        XCTAssertEqual(ctx.deviceType, "mac")
        XCTAssertEqual(ctx.osName, "macOS")
        #endif
    }

    func test_current_missingInfoPlistKeys_fallBackToUnknown() {
        // A bare Bundle without Info.plist values simulates a host with no
        // version metadata (rare, but e.g. `swift test` under SwiftPM where
        // the test bundle carries no CFBundleShortVersionString). Whatever
        // the host provides, both fields are always non-empty strings.
        let ctx = DeviceContext.current(bundle: Bundle(for: DeviceContextTests.self))
        XCTAssertFalse(ctx.appVersion.isEmpty)
        XCTAssertFalse(ctx.appBuild.isEmpty)
    }
}
