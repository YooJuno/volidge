// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vol",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Vol", targets: ["Vol"])
    ],
    targets: [
        .target(
            name: "VolAtomics",
            path: "Sources/VolAtomics",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Vol",
            dependencies: ["VolAtomics"],
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
