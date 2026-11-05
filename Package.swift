// swift-tools-version: 6.2
import PackageDescription

// GhosttyKit.xcframework comes from scripts/build-libghostty.sh (Ghostty v1.4.0, built with
// Zig 0.17.0). It is a static library, so the frameworks it calls into are linked here.
let package = Package(
    name: "hantuu",
    platforms: [.macOS(.v26)],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),
        .executableTarget(
            name: "hantuu",
            dependencies: ["GhosttyKit"],
            path: "Sources/hantuu",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("WebKit"),
                .linkedFramework("PDFKit"),
                .linkedLibrary("c++"),
            ]
        ),
        // The session helper that keeps agents running after the app quits. Plain C: it's all
        // fork, setsid, ptys and sockets. build.sh copies it next to the app's executable.
        .executableTarget(
            name: "hantuu-session",
            path: "Sources/hantuu-session"
        ),
    ]
)
