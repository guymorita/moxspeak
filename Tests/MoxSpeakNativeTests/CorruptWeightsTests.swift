import Foundation
import Testing
@testable import MoxSpeakNative

/// A weights file that exists but cannot be parsed is a *reportable* condition, not a
/// crash. `NativeModelAssets.validate()` only checks that the file is present, so an
/// interrupted copy out of the DMG — the largest file in the bundle, truncated — used to
/// reach `WeightLoader.loadWeights` and take the process down with SIGTRAP from a `try!`.
@Suite struct CorruptWeightsTests {

    @Test func unreadableWeightsThrowInsteadOfTrapping() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moxspeak-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let assets = NativeModelAssets(directory: dir, precision: .float16)
        // Present, so `validate()` passes, but not a safetensors file.
        try Data("not a safetensors file".utf8).write(to: assets.weightsURL)
        try assets.validate()

        #expect(throws: (any Error).self) {
            _ = try NativeKokoroEngine(assets: assets)
        }
    }

    /// What the user reads, and what Sentry records, is the `description`. MLX's own
    /// message names an absolute path under the user's home directory; that must not
    /// reach either one.
    @Test func theMessageIsActionableAndCarriesNoFilePath() {
        let error = NativeKokoroEngine.SynthesisError.weightsUnreadable(
            underlying: "[load_safetensors] Invalid json header length file "
                + "/Users/someone/Applications/MoxSpeak.app/kokoro-v1_0-fp16.safetensors")
        let shown = "\(error)"

        #expect(shown.contains("Reinstalling MoxSpeak"))
        #expect(!shown.contains("/Users/"))
        #expect(!shown.contains(".safetensors"))
        #expect(!shown.contains("load_safetensors"))
    }
}
