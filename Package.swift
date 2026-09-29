// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kuroko",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate"
        ),
        .target(
            name: "KurokoCore",
            path: "Sources/KurokoCore"
        ),
        .executableTarget(
            name: "Kuroko",
            dependencies: ["CGVirtualDisplayPrivate", "KurokoCore"],
            path: "Sources/Kuroko",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "KurokoCoreTests",
            dependencies: ["KurokoCore"],
            path: "Tests/KurokoCoreTests"
        ),
    ]
)
