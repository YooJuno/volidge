// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vol",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Vol", targets: ["Vol"])
    ],
    targets: [
        .executableTarget(
            name: "Vol",
            path: "Sources/Vol",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
