// swift-tools-version: 6.0
import PackageDescription

// Build with Xcode's toolchain: the Makefile sets DEVELOPER_DIR, because the
// Command Line Tools can't run swift-testing or XCTest.
let package = Package(
    name: "UsageMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageMonitor", targets: ["UsageMonitorApp"]),
    ],
    targets: [
        // Foundation, SQLite3 and Security only. No AppKit or SwiftUI
        // (`make test` checks the imports).
        .target(name: "UsageCore"),
        // AppKit + SwiftUI. Composition root and UI.
        .executableTarget(name: "UsageMonitorApp", dependencies: ["UsageCore"]),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "UsageMonitorAppTests",
            dependencies: ["UsageMonitorApp", "UsageCore"]
        ),
    ]
)
