// swift-tools-version: 6.0
import PackageDescription

// Vendored third-party sources live under Sources/Vendor (see Sources/Vendor/VENDORED.md).
// Swift 5 language mode only: upstream is not written for Swift 6 strict concurrency and
// converting it would make every future re-vendor a merge conflict. Warnings are NOT
// suppressed — the vendored tree currently compiles clean at this deployment target, and
// keeping diagnostics on is how we find out when a new upstream version stops doing so.
let vendoredSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5)
]

let package = Package(
    name: "MoxSpeak",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoxSpeakCore", targets: ["MoxSpeakCore"]),
        .library(name: "MoxSpeakNative", targets: ["MoxSpeakNative"]),
        .executable(name: "moxspeak", targets: ["moxspeak"]),
        .executable(name: "MoxSpeakApp", targets: ["MoxSpeakApp"]),
        .executable(name: "moxspeak-native", targets: ["moxspeak-native"]),
    ],
    dependencies: [
        // Required by the vendored MisakiSwift (its fallback G2P net is an MLX BART model)
        // and by the vendored KokoroSwift acoustic model. Pinned exactly: MLX's Swift API
        // moves, and the metallib we ship has to match the version we compile against.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
    ],
    targets: [
        // MARK: - Ours

        // No MLX, no model weights, no native engine. Stays buildable and testable with
        // plain `swift test`.
        .target(name: "MoxSpeakCore"),

        .executableTarget(name: "moxspeak", dependencies: ["MoxSpeakCore"]),
        // Depends on the native engine so the shipped `.app` *contains* a speech engine —
        // weights, voices, lexicon and metallib all inside the bundle — and, since Phase 6,
        // drives it by default. `OpenAICompatibleProvider` stays selectable from the menu:
        // it is how someone points MoxSpeak at a remote or beefier engine, and the escape
        // hatch if the native path ever regresses. Linking (Phase 5) and switching
        // (Phase 6) were deliberately separate steps so a packaging problem and a
        // behaviour change could not be confused for each other.
        .executableTarget(name: "MoxSpeakApp", dependencies: ["MoxSpeakCore", "MoxSpeakNative"]),

        // Text -> 24 kHz mono 16-bit PCM, entirely in-process. Depends on Core; Core
        // does not depend on it.
        .target(
            name: "MoxSpeakNative",
            dependencies: [
                "MoxSpeakCore",
                "KokoroSwift",
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),

        // Harness for the native engine: synthesis, latency measurement, WAV/PCM dumps.
        .executableTarget(name: "moxspeak-native", dependencies: ["MoxSpeakNative"]),

        .testTarget(name: "MoxSpeakCoreTests", dependencies: ["MoxSpeakCore"]),
        .testTarget(name: "MoxSpeakAppTests", dependencies: ["MoxSpeakApp"]),

        // The synthesis half of this suite skips itself when the weights are not on
        // disk, so a fresh checkout still runs it green.
        //
        // MLX is a direct dependency of the *tests* and deliberately not of the provider:
        // the performance envelope suite constrains MLX's allocator and device to stand in
        // for a weaker Mac, and that is a measurement affordance, not something the
        // shipped engine should carry.
        .testTarget(
            name: "MoxSpeakNativeTests",
            dependencies: [
                "MoxSpeakNative",
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),

        // MARK: - Vendored (Sources/Vendor)

        .target(
            name: "MLXUtilsLibrary",
            dependencies: [.product(name: "MLX", package: "mlx-swift")],
            path: "Sources/Vendor/MLXUtilsLibrary",
            exclude: ["LICENSE"],
            swiftSettings: vendoredSettings
        ),

        .target(
            name: "MisakiSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                "MLXUtilsLibrary",
            ],
            path: "Sources/Vendor/MisakiSwift",
            exclude: ["LICENSE"],
            resources: [.copy("Resources")],
            swiftSettings: vendoredSettings
        ),

        .target(
            name: "KokoroSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                "MisakiSwift",
                "MLXUtilsLibrary",
            ],
            path: "Sources/Vendor/KokoroSwift",
            exclude: ["LICENSE"],
            resources: [.copy("Resources")],
            swiftSettings: vendoredSettings
        ),
    ]
)
