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
        .executableTarget(
            name: "DisplayBuddy",
            dependencies: ["CPrivate"],
            path: "Sources/DisplayBuddy",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
