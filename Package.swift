// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Speakeasy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpeakeasyCore", targets: ["SpeakeasyCore"]),
        .executable(name: "speakeasy", targets: ["speakeasy"]),
        .executable(name: "SpeakeasyApp", targets: ["SpeakeasyApp"]),
    ],
    targets: [
        .target(name: "SpeakeasyCore"),
        .executableTarget(name: "speakeasy", dependencies: ["SpeakeasyCore"]),
        .executableTarget(name: "SpeakeasyApp", dependencies: ["SpeakeasyCore"]),
        .testTarget(name: "SpeakeasyCoreTests", dependencies: ["SpeakeasyCore"]),
        .testTarget(name: "SpeakeasyAppTests", dependencies: ["SpeakeasyApp"]),
    ]
)
