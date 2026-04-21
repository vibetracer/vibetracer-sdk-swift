// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VibeTracer",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "VibeTracer", targets: ["VibeTracer"]),
    ],
    targets: [
        .target(
            name: "VibeTracer",
            path: "Sources/VibeTracer",
            resources: [
                // Privacy manifest must live inside the target; SwiftPM rejects
                // resource paths with `..`. Path is relative to the target's
                // `path` (Sources/VibeTracer/).
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "VibeTracerTests",
            dependencies: ["VibeTracer"],
            path: "Tests/VibeTracerTests"
        ),
    ]
)
