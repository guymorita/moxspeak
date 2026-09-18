import Testing
import Foundation
@testable import MoxSpeakNative
import MoxSpeakCore

// These run with no weights on disk. Everything that needs a 312 MB file lives in
// NativeSynthesisTests and skips itself when the file is absent.

@Test func precisionSelectsTheWeightFile() {
    let directory = URL(fileURLWithPath: "/models")
    #expect(NativeModelAssets(directory: directory, precision: .float32)
        .weightsURL.lastPathComponent == "kokoro-v1_0.safetensors")
    #expect(NativeModelAssets(directory: directory, precision: .float16)
        .weightsURL.lastPathComponent == "kokoro-v1_0-fp16.safetensors")
}

@Test func voicesLiveInASubdirectory() {
    let assets = NativeModelAssets(directory: URL(fileURLWithPath: "/models"))
    #expect(assets.voicesDirectory.path == "/models/voices")
    #expect(assets.voiceURL(named: "af_bella").path == "/models/voices/af_bella.safetensors")
}

@Test func environmentOverrideWinsOverEverything() {
    let directory = NativeModelAssets.defaultDirectory(
        environment: ["MOXSPEAK_MODEL_DIR": "/somewhere/else"]
    )
    #expect(directory.path == "/somewhere/else")
}

@Test func environmentOverrideExpandsATilde() {
    let directory = NativeModelAssets.defaultDirectory(environment: ["MOXSPEAK_MODEL_DIR": "~/m"])
    #expect(!directory.path.hasPrefix("~"))
    #expect(directory.path.hasSuffix("/m"))
}

@Test func anEmptyOverrideIsIgnoredRatherThanObeyed() {
    // An unset-but-exported variable is a real thing that happens in launchd plists and
    // CI. Treating "" as a model directory would send resolution to the filesystem root.
    let directory = NativeModelAssets.defaultDirectory(environment: ["MOXSPEAK_MODEL_DIR": ""])
    #expect(directory.path != "")
    #expect(directory.path != "/")
}

@Test func validationNamesTheMissingDirectory() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let assets = NativeModelAssets(directory: missing)
    #expect(throws: NativeModelAssets.ResolutionError.directoryMissing(missing)) {
        try assets.validate()
    }
}

@Test func validationNamesTheMissingWeightFileWhenTheDirectoryExists() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let assets = NativeModelAssets(directory: directory)
    #expect(throws: NativeModelAssets.ResolutionError.weightsMissing(assets.weightsURL)) {
        try assets.validate()
    }
}

@Test func availableVoicesIsEmptyRatherThanThrowingWhenTheDirectoryIsGone() {
    let assets = NativeModelAssets(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    #expect(assets.availableVoices().isEmpty)
}

@Test func availableVoicesListsBasenamesSorted() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let voices = directory.appendingPathComponent("voices", isDirectory: true)
    try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for name in ["bm_george.safetensors", "af_bella.safetensors", "notes.txt"] {
        try Data().write(to: voices.appendingPathComponent(name))
    }

    #expect(NativeModelAssets(directory: directory).availableVoices() == ["af_bella", "bm_george"])
}

// MARK: - PCM

// The engine's output has to be byte-for-byte what the existing playback path already
// consumes from the HTTP provider. Nothing downstream inspects the format, so a wrong
// sample width or byte order would play as noise rather than fail.

@Test func nativeOutputFormatIsExactlyTheFormatPlaybackExpects() {
    #expect(NativeKokoroEngine.outputFormat == AudioFormat.kokoroPCM)
    #expect(NativeKokoroEngine.outputFormat.sampleRate == 24000)
    #expect(NativeKokoroEngine.outputFormat.channels == 1)
    #expect(NativeKokoroEngine.outputFormat.bitDepth == 16)
    #expect(NativeKokoroEngine.outputFormat.isRawPCM)
}

@Test func pcmIsTwoBytesPerSample() {
    #expect(NativeKokoroEngine.pcm16(from: [Float](repeating: 0, count: 100)).count == 200)
    #expect(NativeKokoroEngine.pcm16(from: []).isEmpty)
}

@Test func pcmIsLittleEndianSigned16() {
    let data = NativeKokoroEngine.pcm16(from: [0.0, 1.0, -1.0, 0.5])
    let values: [Int16] = stride(from: 0, to: data.count, by: 2).map {
        Int16(littleEndian: Int16(data[$0]) | (Int16(bitPattern: UInt16(data[$0 + 1]) << 8)))
    }
    #expect(values[0] == 0)
    #expect(values[1] == 32767)
    #expect(values[2] == -32767)
    #expect(values[3] == 16383)
}

@Test func pcmClampsRatherThanWrappingOnOverdrivenSamples() {
    // iSTFTNet output is not guaranteed to stay inside [-1, 1]. Wrapping instead of
    // clamping turns a loud sample into a full-scale sample of the opposite sign, which
    // is an audible click.
    let data = NativeKokoroEngine.pcm16(from: [4.0, -4.0])
    #expect(Array(data) == [0xFF, 0x7F, 0x01, 0x80])
}

@Test func pcmDurationMatchesWhatTheFormatWouldCompute() {
    // One second of 24 kHz mono 16-bit audio, measured the way the session measures it.
    let data = NativeKokoroEngine.pcm16(from: [Float](repeating: 0, count: 24000))
    #expect(Double(data.count) / Double(AudioFormat.kokoroPCM.bytesPerSecond) == 1.0)
}

// MARK: - Resolving out of the app bundle
//
// Phase 5: the shipped `.app` carries the weights and voices in
// `Contents/Resources/Models`, and the engine has to find them there rather than through
// any path relative to this source tree. These use a `Bundle` built over a temporary
// directory — for a directory that is not a wrapped `.app`, `Bundle.resourceURL` is the
// directory itself, which is also exactly the shape of a plain `swift build` output
// directory, so the same test covers both.

/// Makes a throwaway directory usable as a `Bundle`, optionally containing `Models/`.
private func temporaryBundle(withModels: Bool) throws -> (Bundle, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if withModels {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Models", isDirectory: true),
            withIntermediateDirectories: true)
    }
    guard let bundle = Bundle(url: root) else {
        throw NativeModelAssets.ResolutionError.directoryMissing(root)
    }
    return (bundle, root)
}

@Test func modelsInsideTheBundleAreFoundThroughTheBundleNotTheSourceTree() throws {
    let (bundle, root) = try temporaryBundle(withModels: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let found = try #require(NativeModelAssets.bundleModelsDirectory(bundle: bundle))
    #expect(found.standardizedFileURL.path
            == root.appendingPathComponent("Models").standardizedFileURL.path)
}

@Test func aBundleWithoutModelsResolvesToNothingRatherThanAPathThatDoesNotExist() throws {
    let (bundle, root) = try temporaryBundle(withModels: false)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(NativeModelAssets.bundleModelsDirectory(bundle: bundle) == nil)
}

@Test func aFileNamedModelsIsNotAModelDirectory() throws {
    let (bundle, root) = try temporaryBundle(withModels: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("Models"))

    // `fileExists(atPath:)` alone would say yes here and resolution would then fail deep
    // inside the loader with a confusing error, so the directory check is load-bearing.
    #expect(NativeModelAssets.bundleModelsDirectory(bundle: bundle) == nil)
}

@Test func theBundleOutranksBothApplicationSupportAndTheCheckout() throws {
    let (bundle, root) = try temporaryBundle(withModels: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // No environment override, and the developer checkout's Models/ may well exist on this
    // machine — the point of the assertion is that the bundle beats it anyway.
    let resolved = NativeModelAssets.defaultDirectory(environment: [:], bundle: bundle)
    #expect(resolved.standardizedFileURL.path
            == root.appendingPathComponent("Models").standardizedFileURL.path)
}

@Test func theEnvironmentOverrideStillOutranksTheBundle() throws {
    let (bundle, root) = try temporaryBundle(withModels: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let resolved = NativeModelAssets.defaultDirectory(
        environment: ["MOXSPEAK_MODEL_DIR": "/somewhere/else"], bundle: bundle)
    #expect(resolved.path == "/somewhere/else")
}

@Test func resolveDefaultCarriesTheBundleThroughToTheAssets() throws {
    let (bundle, root) = try temporaryBundle(withModels: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let assets = NativeModelAssets.resolveDefault(precision: .float16, environment: [:], bundle: bundle)
    #expect(assets.weightsURL.standardizedFileURL.path
            == root.appendingPathComponent("Models/kokoro-v1_0-fp16.safetensors")
                   .standardizedFileURL.path)
}

@Test func theBundledModelDirectoryIsAnAbsoluteURLWithNoBaseLeftOnIt() throws {
    let (bundle, root) = try temporaryBundle(withModels: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let found = try #require(NativeModelAssets.bundleModelsDirectory(bundle: bundle))

    // `Bundle.resourceURL` is base-relative. `URL.path` hides that; `URL.path()` does not,
    // and `URL.path()` is what mlx-swift's loader calls — so a URL that still carries a
    // base reaches MLX as "Contents/Resources/Models/kokoro-v1_0-fp16.safetensors" and the
    // process aborts inside `try! MLX.loadArrays`. Both accessors must agree, and both
    // must be absolute.
    #expect(found.baseURL == nil)
    #expect(found.path().hasPrefix("/"))
    // Same path from both accessors. (`path()` keeps the trailing slash a directory URL
    // carries and `path` drops it; that difference is cosmetic, a missing prefix is not.)
    #expect(found.path().hasPrefix(found.path))

    let weights = NativeModelAssets(directory: found, precision: .float16).weightsURL
    #expect(weights.path().hasPrefix("/"))
    #expect(weights.path().hasSuffix("/Models/kokoro-v1_0-fp16.safetensors"))
}
