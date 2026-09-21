import Foundation
import MLX
import MoxSpeakCore
import KokoroSwift

/// In-process Kokoro text-to-speech: text in, raw PCM out, no server.
///
/// Not `Sendable` and not thread-safe. MLX's default stream and the vendored KokoroSwift
/// graph are both shared mutable state, and the G2P lexicon is loaded lazily on first use.
/// One engine belongs to one isolation domain; the provider that wraps it for the app is
/// responsible for that and is a separate piece of work.
public final class NativeKokoroEngine {

    public enum SynthesisError: Error, CustomStringConvertible {
        case emptyText
        case voiceLoadFailed(name: String, underlying: String)
        case voiceMalformed(name: String)
        case textTooLong(characters: Int)
        case engine(String)
        /// The weight file is present but could not be parsed. `underlying` is MLX's own
        /// message; it names an absolute path, so it is deliberately kept out of
        /// `description` — that string reaches both the user's screen and Sentry, and
        /// neither may carry a filesystem path.
        case weightsUnreadable(underlying: String)

        public var description: String {
            switch self {
            case .emptyText:
                "Nothing to synthesize."
            case .voiceLoadFailed(let name, let underlying):
                "Could not load voice '\(name)': \(underlying)"
            case .voiceMalformed(let name):
                "Voice '\(name)' has no 'voice' tensor."
            case .textTooLong(let characters):
                "Text of \(characters) characters exceeds the model's context window; segment it first."
            case .engine(let message):
                message
            case .weightsUnreadable:
                "MoxSpeak's voice model is damaged or was copied incompletely. "
                + "Reinstalling MoxSpeak will replace it."
            }
        }
    }

    /// What this engine produces. Byte-identical in shape to what the HTTP provider
    /// returns, so it drops into the existing playback path unchanged.
    public nonisolated static let outputFormat: AudioFormat = .kokoroPCM

    /// Kokoro's positional encoding runs out at 512 tokens. Phonemes are shorter than
    /// characters, so a character cap well under that is a safe, cheap pre-check; it
    /// matches the cap the HTTP provider already advertises.
    public nonisolated static let recommendedCharacterCap = 150

    public let assets: NativeModelAssets

    private let tts: KokoroTTS
    private var voiceCache: [String: MLXArray] = [:]

    /// Loads the model. Expensive (mmaps ~310 MB), so do it once and keep the engine.
    public init(assets: NativeModelAssets = .resolveDefault()) throws {
        // Order matters: MLX aborts the process if its kernels are missing, so that check
        // has to come before anything touches MLX.
        try NativeRuntime.requireMetalLibrary()
        try assets.validate()
        self.assets = assets
        // `assets.validate()` above proves the file is *there*; it cannot prove it parses.
        // The weights are the largest thing in the bundle, so a copy interrupted partway
        // out of the DMG leaves a truncated file that passes validation. Upstream trapped
        // on it (SIGTRAP, no message, nothing actionable in the crash report); translate
        // it into something a person can act on instead.
        do {
            self.tts = try KokoroTTS(modelPath: assets.weightsURL, g2p: .misaki)
        } catch {
            throw SynthesisError.weightsUnreadable(underlying: "\(error)")
        }
    }

    /// Runs one throwaway synthesis so the first real request does not pay for lazy
    /// lexicon loading, Metal pipeline compilation and MLX's first-allocation costs.
    /// Measured in the spike at ~1 s warm-cache, ~5 s cold.
    @discardableResult
    public func warmUp(voice: String = "af_bella") throws -> TimeInterval {
        let start = Date()
        _ = try synthesizeSamples(text: "Warming up.", voice: voice, speed: 1.0)
        return Date().timeIntervalSince(start)
    }

    /// Text -> raw 24 kHz mono signed-16-bit-LE PCM, exactly `AudioFormat.kokoroPCM`.
    public func synthesize(text: String, voice: String = "af_bella", speed: Double = 1.0) throws -> Data {
        let samples = try synthesizeSamples(text: text, voice: voice, speed: speed)
        return Self.pcm16(from: samples)
    }

    /// Text -> float samples in [-1, 1] at 24 kHz. The form the comparison harness wants,
    /// and the form a future streaming path would slice.
    public func synthesizeSamples(text: String, voice: String, speed: Double = 1.0) throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SynthesisError.emptyText }

        let style = try voiceVector(named: voice)
        do {
            let (samples, _) = try tts.generateAudio(
                voice: style,
                language: .enUS,
                text: trimmed,
                speed: Float(speed)
            )
            return samples
        } catch KokoroTTS.KokoroTTSError.tooManyTokens {
            throw SynthesisError.textTooLong(characters: trimmed.count)
        } catch {
            throw SynthesisError.engine("\(error)")
        }
    }

    /// The phonemes the model will actually be fed. Exposed because G2P is the part of
    /// this pipeline most likely to be wrong, and a wrong pronunciation is invisible in
    /// any acoustic metric.
    public func phonemes(for text: String) throws -> String {
        try tts.phonemize(text: text, language: .enUS)
    }

    public func availableVoices() -> [String] { assets.availableVoices() }

    // MARK: - Voices

    private func voiceVector(named name: String) throws -> MLXArray {
        if let cached = voiceCache[name] { return cached }

        let url = assets.voiceURL(named: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NativeModelAssets.ResolutionError.voiceMissing(
                name: name, searched: assets.voicesDirectory
            )
        }

        let arrays: [String: MLXArray]
        do {
            arrays = try MLX.loadArrays(url: url)
        } catch {
            throw SynthesisError.voiceLoadFailed(name: name, underlying: "\(error)")
        }
        guard let vector = arrays["voice"] else {
            throw SynthesisError.voiceMalformed(name: name)
        }

        voiceCache[name] = vector
        return vector
    }

    // MARK: - PCM

    /// Float samples -> signed 16-bit little-endian, clamped. Written against a raw byte
    /// buffer rather than `Data.append` per sample: a 10-second utterance is 240,000
    /// samples and the naive version dominated the measured generation time.
    static func pcm16(from samples: [Float]) -> Data {
        var bytes = [UInt8](repeating: 0, count: samples.count * 2)
        bytes.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for index in samples.indices {
                let clamped = max(-1.0, min(1.0, samples[index]))
                out[index] = Int16(clamped * 32767.0).littleEndian
            }
        }
        return Data(bytes)
    }
}
