import Foundation

/// A text-to-speech engine.
///
/// "OpenAI-compatible" guarantees a request shape and nothing else — not sample rates,
/// not streaming semantics, not error payloads. Every one of those is declared here so
/// the session can adapt rather than assume.
public protocol SpeechProvider: Sendable {
    /// Exactly what `synthesize` returns. Validated against the first response.
    var outputFormat: AudioFormat { get }

    /// False when the engine only returns complete responses. Affects chunk sizing only.
    var supportsIncrementalStreaming: Bool { get }

    /// Largest input this engine handles reliably. An engine property, not a constant.
    var recommendedCharacterCap: Int { get }

    /// Synthesize one chunk. Must honor `Task` cancellation.
    func synthesize(text: String, voice: String, speed: Double) async throws -> Data

    func listVoices() async throws -> [Voice]
}

/// In-memory provider for tests. No network, no audio hardware.
public actor FakeProvider: SpeechProvider {

    public enum Behavior: Sendable {
        case normal
        case empty
        /// Returns this fraction of the audio the text should have produced.
        case short(fraction: Double)
        case failing(SpeechError)
        case slow(seconds: Double)
        /// Fails the first `count` calls with empty audio, then behaves normally.
        /// Models the real backend, whose failures are intermittent rather than deterministic.
        case failingFirst(count: Int)
    }

    public nonisolated var outputFormat: AudioFormat { .kokoroPCM }
    public nonisolated var supportsIncrementalStreaming: Bool { true }
    public nonisolated var recommendedCharacterCap: Int { 150 }

    private var behavior: Behavior = .normal
    private let estimator = DurationEstimator()
    private var failingFirstRemaining = 0

    public private(set) var callCount = 0
    public private(set) var cancelledCount = 0
    public private(set) var lastText: String?

    public init() {}

    public func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
        if case .failingFirst(let count) = behavior {
            failingFirstRemaining = count
        }
    }

    public func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
        callCount += 1
        lastText = text

        switch behavior {
        case .failing(let error):
            throw error

        case .slow(let seconds):
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                cancelledCount += 1
                throw error
            }
            return audio(forCharacters: text.count, fraction: 1.0)

        case .empty:
            return Data()

        case .short(let fraction):
            return audio(forCharacters: text.count, fraction: fraction)

        case .failingFirst:
            if failingFirstRemaining > 0 {
                failingFirstRemaining -= 1
                return Data()
            }
            return audio(forCharacters: text.count, fraction: 1.0)

        case .normal:
            try Task.checkCancellation()
            return audio(forCharacters: text.count, fraction: 1.0)
        }
    }

    public func listVoices() async throws -> [Voice] {
        [Voice(id: "af_bella", name: "af_bella"), Voice(id: "af_sky", name: "af_sky")]
    }

    private func audio(forCharacters count: Int, fraction: Double) -> Data {
        let seconds = estimator.estimate(characterCount: count) * fraction
        let bytes = Int(seconds * Double(outputFormat.bytesPerSecond))
        // Silence is fine; only the byte count carries meaning in tests.
        return Data(count: max(0, bytes))
    }
}
