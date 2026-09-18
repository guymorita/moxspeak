import Foundation

/// Where the native engine's weights and voice vectors live on disk.
///
/// The files are hundreds of megabytes and are deliberately not in git (see
/// `Sources/Vendor/VENDORED.md` for provenance and the re-fetch recipe). Resolution is
/// therefore a runtime concern, and a missing file is a normal, reportable condition —
/// not a crash.
public struct NativeModelAssets: Sendable, Equatable {

    /// Numeric precision of the weight file. The two precisions are two different files
    /// on disk, converted offline; nothing is cast at load time.
    public enum Precision: String, Sendable, CaseIterable {
        case float32
        case float16

        /// Weight file basename for this precision.
        var weightsFilename: String {
            switch self {
            case .float32: "kokoro-v1_0.safetensors"
            case .float16: "kokoro-v1_0-fp16.safetensors"
            }
        }
    }

    public enum ResolutionError: Error, CustomStringConvertible, Equatable {
        case directoryMissing(URL)
        case weightsMissing(URL)
        case voiceMissing(name: String, searched: URL)

        public var description: String {
            switch self {
            case .directoryMissing(let url):
                "No native model directory at \(url.path). Set MOXSPEAK_MODEL_DIR or see Sources/Vendor/VENDORED.md."
            case .weightsMissing(let url):
                "No Kokoro weights at \(url.path). See Sources/Vendor/VENDORED.md for the re-fetch recipe."
            case .voiceMissing(let name, let searched):
                "No voice '\(name).safetensors' in \(searched.path)."
            }
        }
    }

    /// Directory holding the weight files and a `voices/` subdirectory.
    public let directory: URL
    public let precision: Precision

    public init(directory: URL, precision: Precision = .float32) {
        self.directory = directory
        self.precision = precision
    }

    public var weightsURL: URL {
        directory.appendingPathComponent(precision.weightsFilename)
    }

    public var voicesDirectory: URL {
        directory.appendingPathComponent("voices", isDirectory: true)
    }

    public func voiceURL(named name: String) -> URL {
        voicesDirectory.appendingPathComponent("\(name).safetensors")
    }

    /// Subdirectory of the bundle's resources that holds the weights and `voices/`.
    /// `MoxSpeak.app/Contents/Resources/Models` in a shipped build.
    public static let bundleSubdirectory = "Models"

    /// The model directory inside the running bundle, or nil when there isn't one.
    ///
    /// This is the shipping path and the reason the app is self-contained: `build-app.sh`
    /// copies the fp16 weights and `voices/` into `Contents/Resources/Models`, and
    /// `Bundle.main.resourceURL` finds them wherever the `.app` has been dragged to. No
    /// path relative to the source tree is involved, so it keeps working on a machine that
    /// has never seen this repository.
    ///
    /// It is also harmless during development. For a bare `swift build` executable
    /// `Bundle.main.resourceURL` is the directory the binary sits in (`.build/release`),
    /// which has no `Models` subdirectory, so this returns nil and resolution falls
    /// through to the checkout. Under `swift test` `Bundle.main` is the `.xctest` harness,
    /// same story.
    public static func bundleModelsDirectory(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        // `.absoluteURL` is load-bearing, and was found the hard way. `Bundle.resourceURL`
        // hands back a *base-relative* URL — "Contents/Resources/" relative to the .app —
        // and while `URL.path` flattens that, `URL.path()` (the newer accessor, which is
        // what mlx-swift's `loadArrays(url:)` calls) returns only the relative half. The
        // symptom was MLX aborting the process with
        //
        //     Failed to open file Contents/Resources/Models/kokoro-v1_0-fp16.safetensors
        //
        // from a bundle where the file was plainly there. Collapsing the base in here means
        // every URL derived from this one is absolute, whoever reads it and however.
        guard let resources = bundle.resourceURL?.absoluteURL else { return nil }
        let candidate = resources.appendingPathComponent(bundleSubdirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return candidate
    }

    /// The default model directory, in precedence order:
    ///
    /// 1. `MOXSPEAK_MODEL_DIR`
    /// 2. `<bundle>/Contents/Resources/Models` — what a shipped `.app` carries inside it
    /// 3. `~/Library/Application Support/MoxSpeak/models` — a hand-installed override
    /// 4. `<repo>/Models` — where a developer checkout keeps them (gitignored)
    ///
    /// Only 1 is authoritative; 2 through 4 are tried in order and the first that exists
    /// wins. The bundle sits above Application Support deliberately: the app ships with a
    /// known-good, signed set of weights and that is what it should use, not whatever an
    /// earlier experiment left in a user directory.
    ///
    /// If none exists, 3 is returned so the error message names an install location rather
    /// than someone's checkout.
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> URL {
        if let override = environment["MOXSPEAK_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }

        if let bundled = bundleModelsDirectory(bundle: bundle, fileManager: fileManager) {
            return bundled
        }

        let appSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MoxSpeak/models", isDirectory: true)
        if fileManager.fileExists(atPath: appSupport.path) {
            return appSupport
        }

        if let repo = repositoryModelsDirectory(fileManager: fileManager) {
            return repo
        }

        return appSupport
    }

    /// Walks up from this source file's compile-time location looking for `Models/`.
    /// Used only in a developer checkout; returns nil in a shipped app.
    private static func repositoryModelsDirectory(fileManager: FileManager) -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Models", isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    public static func resolveDefault(
        precision: Precision = .float32,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> NativeModelAssets {
        NativeModelAssets(directory: defaultDirectory(environment: environment, bundle: bundle),
                          precision: precision)
    }

    /// Throws unless the weight file for this precision is present. Voices are checked
    /// per-request, not here: a missing voice is a much smaller problem than a missing model.
    public func validate(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ResolutionError.directoryMissing(directory)
        }
        guard fileManager.fileExists(atPath: weightsURL.path) else {
            throw ResolutionError.weightsMissing(weightsURL)
        }
    }

    /// Voice names available on disk, sorted. Empty if the directory is missing.
    public func availableVoices(fileManager: FileManager = .default) -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: voicesDirectory.path)) ?? []
        return contents
            .filter { $0.hasSuffix(".safetensors") }
            .map { String($0.dropLast(".safetensors".count)) }
            .sorted()
    }
}
