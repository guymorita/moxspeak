// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoxSpeak",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoxSpeakCore", targets: ["MoxSpeakCore"]),
        .executable(name: "moxspeak", targets: ["moxspeak"]),
        .executable(name: "MoxSpeakApp", targets: ["MoxSpeakApp"]),
    ],
    targets: [
        .target(name: "MoxSpeakCore"),
        .executableTarget(name: "moxspeak", dependencies: ["MoxSpeakCore"]),
        .executableTarget(name: "MoxSpeakApp", dependencies: ["MoxSpeakCore"]),
        .testTarget(name: "MoxSpeakCoreTests", dependencies: ["MoxSpeakCore"]),
        .testTarget(name: "MoxSpeakAppTests", dependencies: ["MoxSpeakApp"]),
    ]
)
