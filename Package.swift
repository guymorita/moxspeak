// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Speakeasy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpeakeasyCore", targets: ["SpeakeasyCore"]),
        .executable(name: "speakeasy", targets: ["speakeasy"]),
    ],
    targets: [
        .target(name: "SpeakeasyCore"),
        .executableTarget(name: "speakeasy", dependencies: ["SpeakeasyCore"]),
        .testTarget(name: "SpeakeasyCoreTests", dependencies: ["SpeakeasyCore"]),
    ]
)
