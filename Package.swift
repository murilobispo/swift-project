// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-project",
    dependencies: [
        // SwiftCrossUI: a cross-platform, SwiftUI-inspired declarative UI framework.
        // We use the GtkBackend product directly (GTK 4 on Linux) instead of
        // DefaultBackend, whose platform-conditioned dependencies trip up Swift
        // 6.4's default `swiftbuild` engine (it tries to compile the Windows
        // backend even on Linux).
        .package(
            url: "https://github.com/moreSwift/swift-cross-ui",
            .upToNextMinor(from: "0.10.0")
        ),
        // ImageFormats: raw-pixel image type used to display captured camera
        // frames. Already in the graph via SwiftCrossUI; declared here so our
        // target can import it directly.
        .package(
            url: "https://github.com/stackotter/swift-image-formats",
            .upToNextMinor(from: "0.5.0")
        ),
    ],
    targets: [
        .executableTarget(
            name: "swift_project",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "GtkBackend", package: "swift-cross-ui"),
                .product(name: "ImageFormats", package: "swift-image-formats"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
