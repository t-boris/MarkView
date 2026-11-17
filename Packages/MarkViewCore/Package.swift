// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkViewCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MarkViewCore",
            targets: ["MarkViewCore"]
        ),
    ],
    targets: [
        .target(
            name: "MarkViewCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TestSupport",
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "MarkViewCoreTests",
            dependencies: ["MarkViewCore", "TestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
    ]
)
