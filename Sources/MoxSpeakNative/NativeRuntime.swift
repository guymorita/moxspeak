import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Whether this process can actually run MLX kernels.
///
/// MLX needs a compiled Metal library and `swift build` does not produce one — see
/// "The Metal library" in `Sources/Vendor/VENDORED.md`. When it is missing, MLX raises a
/// C++ exception from inside `mlx-c` that surfaces as a process abort, not a Swift error.
/// So the check has to happen before the first MLX call, which is what this is for.
public enum NativeRuntime {

    /// Directory holding the binary this code is linked into. MLX resolves its metallib
    /// relative to the same place (`current_binary_dir()`, via `dladdr`), so this is the
    /// directory that matters — not the working directory and not the main bundle.
    public static var binaryDirectory: URL {
        #if canImport(Darwin)
        var info = Dl_info()
        let symbol = unsafeBitCast(binaryDirectoryAnchor as @convention(c) () -> Void, to: UnsafeRawPointer.self)
        if dladdr(symbol, &info) != 0, let name = info.dli_fname {
            return URL(fileURLWithPath: String(cString: name)).deletingLastPathComponent()
        }
        #endif
        return URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
    }

    /// A C-callable symbol guaranteed to live in whichever image MoxSpeakNative was
    /// linked into. Its body is irrelevant; only its address is used.
    private static let binaryDirectoryAnchor: @convention(c) () -> Void = {}

    /// The metallib MLX will find, searched in MLX's own order. Nil means MLX will abort
    /// on its first kernel launch.
    public static var metalLibraryURL: URL? {
        let directory = binaryDirectory
        let candidates = [
            directory.appendingPathComponent("mlx.metallib"),
            directory.appendingPathComponent("Resources/mlx.metallib"),
            directory.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
            directory.appendingPathComponent("Resources/default.metallib"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static var isAvailable: Bool { metalLibraryURL != nil }

    public struct MetalLibraryMissing: Error, CustomStringConvertible {
        public let searched: URL
        public var description: String {
            """
            No MLX Metal library next to the binary at \(searched.path).
            Run Scripts/build-metallib.sh (see Sources/Vendor/VENDORED.md).
            """
        }
    }

    /// Throws rather than letting MLX abort the process.
    public static func requireMetalLibrary() throws {
        guard isAvailable else { throw MetalLibraryMissing(searched: binaryDirectory) }
    }
}
