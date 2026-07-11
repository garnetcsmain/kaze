// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kaze",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Kaze",
            path: "Sources/Kaze",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
