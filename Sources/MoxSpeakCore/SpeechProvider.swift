import Foundation

/// A text-to-speech engine.
///
/// "OpenAI-compatible" guarantees a request shape and nothing else — not sample rates,
/// not streaming semantics, not error payloads. Every one of those is declared here so
/// the session can adapt rather than assume.
public protocol SpeechProvider: Sendable {
    /// What `synthesize` is declared to return.
    ///
    /// This is trusted, NOT verified: nothing inspects a response and checks it against
    /// this declaration. Every duration in the pipeline is computed by dividing a byte
    /// count by this format's `bytesPerSecond`, so a mis-declared format makes every
    /// computed duration wrong — and with it every validation decision that compares a
    /// measured duration against an estimate. Checking responses against this value is
    /// deliberately deferred to a later plan.
    var outputFormat: AudioFormat { get }

    /// False when the engine only returns complete responses. Affects chunk sizing only.
    var supportsIncrementalStreaming: Bool { get }

    /// Largest input this engine handles reliably. An engine property, not a constant.
    var recommendedCharacterCap: Int { get }

    /// True when this engine expects numbers, money, dates and abbreviations already spelled
    /// out as words, and the session should run `TextNormalizer` before handing text over.
    ///
    /// There is no default. Getting this wrong is silently destructive in both directions: a
    /// server that normalizes for itself (Kokoro-FastAPI) and is also normalized here reads
    /// "$5" as "five dollars dollars", while an engine that normalizes nothing and is told so
    /// wrongly reads "$1,234.56" as a string of unrelated digits. Neither failure throws, so
    /// every provider is made to state its position rather than inherit a guess.
    var requiresTextNormalization: Bool { get }

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

    /// Set at construction so a test can stand up both sides of the normalization decision.
    /// A `let` rather than a settable property: the requirement is `nonisolated`, so a
    /// mutable version would be readable from outside the actor mid-flight.
    public nonisolated let requiresTextNormalization: Bool

    private var behavior: Behavior = .normal
    private let estimator = DurationEstimator()
    private var failingFirstRemaining = 0

    public private(set) var callCount = 0
    public private(set) var cancelledCount = 0
    public private(set) var lastText: String?
    /// The `speed` argument most recently passed to `synthesize`. Nil until the first
    /// call. Exists so tests can assert on the speed the session actually requests —
    /// without it, `synthesize`'s `speed` parameter is accepted and silently ignored,
    /// and a session that regressed to requesting the wrong speed would still pass
    /// every test.
    public private(set) var lastSpeed: Double?

    public init(requiresTextNormalization: Bool = false) {
        self.requiresTextNormalization = requiresTextNormalization
    }

    public func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
        if case .failingFirst(let count) = behavior {
            failingFirstRemaining = count
        }
    }

    public func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
        callCount += 1
        lastText = text
        lastSpeed = speed

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
