// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VENAudioEnhance",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VENApp", targets: ["VENApp"]),
        .executable(name: "ven-cli", targets: ["ven-cli"]),
    ],
    targets: [
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            exclude: ["COPYING"],
            cSettings: [.unsafeFlags(["-O3", "-Wno-everything"])]
        ),
        .target(
            name: "VENDSP",
            dependencies: ["CRNNoise"],
            cSettings: [.unsafeFlags(["-O3", "-ffast-math"])],
            linkerSettings: [.linkedFramework("AudioToolbox")]
        ),
        .target(
            name: "VENCore",
            dependencies: ["VENDSP"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(name: "VENApp", dependencies: ["VENCore"]),
        .executableTarget(name: "ven-cli", dependencies: ["VENCore"]),
    ]
)
