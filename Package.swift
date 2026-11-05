// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "audiotap",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "audiotap",
            path: "Sources/audiotap",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
            ]
        )
    ]
)
