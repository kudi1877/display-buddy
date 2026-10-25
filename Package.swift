// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DisplayBuddy",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CPrivate",
            path: "Sources/CPrivate"
        ),
        // Keep Awake / Presentation Mode logic with no AppKit, so it can be unit-tested.
        .target(
            name: "PresenceCore",
            path: "Sources/PresenceCore"
        ),
        .executableTarget(
            name: "DisplayBuddy",
            dependencies: ["CPrivate", "PresenceCore"],
            path: "Sources/DisplayBuddy",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .testTarget(
            name: "PresenceCoreTests",
            dependencies: ["PresenceCore"],
            path: "Tests/PresenceCoreTests"
        ),
    ]
)
