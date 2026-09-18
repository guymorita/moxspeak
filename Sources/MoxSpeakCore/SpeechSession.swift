import Foundation

/// Orchestrates preparation, segmentation, synthesis and validation.
///
/// Every speak request gets a generation number. In-flight work carries the generation
/// it belongs to, and a response arriving under a stale generation is discarded rather
/// than committed. Without this, replace-while-playing and seeking race against work
/// that has already been abandoned.
public actor SpeechSession {

    public struct ValidationPolicy: Sendable {
        /// Audio shorter than this fraction of the estimate is treated as a failure.
        public var minimumDurationRatio: Double = 0.6
        /// Additional attempts per level, beyond the first. Failures are intermittent,
        /// so a retry is often enough on its own.
        public var maxRetries: Int = 2
        /// How many times a failing chunk may be halved before giving up.
        public var maxSplitDepth: Int = 2
        public init() {}
    }

    private let provider: any SpeechProvider
    private let preparer: TextPreparer
    private let normalizer: TextNormalizer
    private let segmenter: Segmenter
    private let estimator: DurationEstimator
    private let validation: ValidationPolicy

    public private(set) var currentGeneration = 0
    public private(set) var chunks: [Chunk] = []

    private var states: [Int: ChunkState] = [:]
    private var renderTask: Task<Void, Never>?

    /// - Parameter segmenter: Defaults to `nil`, which builds a `Segmenter` from
    ///   `provider.recommendedCharacterCap` — see `Segmenter.Options.init(providerCap:)`.
    ///   `recommendedCharacterCap` has been declared on `SpeechProvider` since the speech
    ///   core shipped and was, until this parameter existed, never read by anything: the
    ///   HTTP provider's 150 (a PyTorch-MPS truncation workaround) and the native
    ///   provider's measured 100 both went in and were both silently ignored, and every
    ///   engine got the same hardcoded `Segmenter()` regardless of what it declared. Pass
    ///   an explicit `Segmenter` only to override that per-provider default (tests that
    ///   exercise segmentation mechanics independent of which provider is in play).
    public init(provider: any SpeechProvider,
                preparer: TextPreparer = TextPreparer(),
                normalizer: TextNormalizer = TextNormalizer(),
                segmenter: Segmenter? = nil,
                estimator: DurationEstimator = DurationEstimator(),
                validation: ValidationPolicy = ValidationPolicy()) {
        self.provider = provider
        self.preparer = preparer
        self.normalizer = normalizer
        self.segmenter = segmenter ?? Segmenter(
            options: Segmenter.Options(providerCap: provider.recommendedCharacterCap))
        self.estimator = estimator
        self.validation = validation
    }

    public func state(of index: Int) -> ChunkState {
        states[index] ?? .pending
    }

    /// Replaces whatever is playing. Returns the new generation.
    ///
    /// There is deliberately no `speed:` parameter. Synthesis always runs at 1.0 — see
    /// `synthesisSpeed` — and playback speed is a downstream concern handled by
    /// `PlaybackEngine.rate`.
    @discardableResult
    public func speak(_ raw: String, voice: String) -> Int {
        cancelAll()

        currentGeneration += 1
        let generation = currentGeneration

        // Preparation always runs; normalization is the engine's call. The two are separate
        // stages on purpose — see `TextNormalizer` — and normalization runs before
        // segmentation so that expanding "Dec." cannot leave a period behind for the
        // segmenter to mistake for the end of a sentence.
        var prepared = preparer.prepare(raw)
        if provider.requiresTextNormalization {
            prepared = normalizer.normalize(prepared)
        }
        chunks = segmenter.segment(prepared)
        states = [:]
        for chunk in chunks { states[chunk.id] = .pending }

        startRendering(generation: generation, voice: voice)
        return generation
    }

    /// The session always synthesizes at 1.0 and never varies it.
    ///
    /// Validation compares the *measured* duration of returned audio against
    /// `DurationEstimator`'s character-count estimate, and that estimate is only valid at
    /// speed 1.0: a request at speed `s` returns audio roughly `1/s` as long, so any other
    /// value silently skews the comparison. Above ~1.67 every healthy chunk would fail the
    /// ratio check and burn the whole retry ladder; below 1.0 a genuinely truncated chunk
    /// would read as acceptable and switch the safety net off entirely.
    ///
    /// Playback speed is not lost by this — it is handled downstream by
    /// `PlaybackEngine`'s `AVAudioUnitTimePitch`, which changes rate instantly and
    /// pitch-corrected with no re-synthesis. `SpeechProvider.synthesize` keeps its `speed`
    /// parameter because engines support it and a future caller may want it.
    private static let synthesisSpeed: Double = 1.0

    /// Cancels every in-flight render task and returns immediately — fire-and-forget.
    /// This does NOT wait for the cancelled work to actually unwind. That's deliberate:
    /// `speak` calls this on the hot path, and correctness does not depend on waiting.
    /// `currentGeneration` is incremented synchronously right after this returns, with
    /// no `await` in between, so any stale task that resumes later already sees the
    /// advanced generation and is discarded by the guards in `render`. Making this
    /// `async` and awaiting completion would couple hotkey latency to however long a
    /// given provider takes to unwind a cancelled call, for a guarantee correctness
    /// doesn't need. Use `cancelAllAndWait()` when you actually need cancellation to
    /// have finished before proceeding (e.g. shutdown).
    public func cancelAll() {
        renderTask?.cancel()
        renderTask = nil
    }

    /// Like `cancelAll()`, but waits for the render task to actually finish before
    /// returning. Use this for shutdown, or anywhere the caller needs cancellation's
    /// effects to be fully settled — not on the `speak` hot path.
    public func cancelAllAndWait() async {
        let task = renderTask
        renderTask = nil
        task?.cancel()
        _ = await task?.value
    }

    /// Test and CLI helper: resolves once rendering has finished.
    public func waitForRenderComplete() async {
        _ = await renderTask?.value
    }

    // MARK: - Rendering

    /// Chunks render one at a time, strictly in document order — not fanned out into one
    /// concurrent request per chunk. The backend runs a single model and serializes
    /// internally, so N concurrent requests just make every one of them, including
    /// chunk 0, wait behind N-1 others: time-to-first-sound scaled with document length
    /// instead of staying flat. Measured directly against the server (4 equal-size
    /// requests): concurrent — first chunk ready at 8.05s, all done at 8.05s; sequential
    /// — first chunk ready at 1.97s, all done at 7.62s. Sequential wins on the metric
    /// that matters and loses nothing on total throughput, since the server was batching
    /// the concurrent requests internally anyway. Synthesis still runs at 7-20x realtime,
    /// so a single sequential render task still comfortably outruns playback — the
    /// continuous-read-ahead intent is preserved, it just no longer stampedes the server.
    private func startRendering(generation: Int, voice: String) {
        let chunksToRender = chunks
        renderTask = Task { [weak self] in
            guard let self else { return }
            for chunk in chunksToRender {
                if Task.isCancelled { return }
                guard await self.currentGeneration == generation else { return }
                await self.render(chunk: chunk,
                                   generation: generation,
                                   voice: voice)
            }
        }
    }

    private func render(chunk: Chunk, generation: Int, voice: String) async {
        guard generation == currentGeneration else { return }
        states[chunk.id] = .synthesizing

        do {
            let data = try await synthesizeValidated(chunk: chunk, voice: voice)
            // The generation may have advanced while this was in flight.
            guard generation == currentGeneration else { return }
            let duration = estimator.duration(ofBytes: data.count, format: provider.outputFormat)
            states[chunk.id] = .rendered(data: data, duration: duration)
        } catch is CancellationError {
            // A cancelled chunk must still reach a terminal state. Leaving it in
            // `.synthesizing` would strand every consumer that polls `state(of:)` for
            // completion (the CLI does exactly that) in an infinite wait. The generation
            // guard still applies: if a newer generation has taken over, these chunk ids
            // belong to someone else's document and must not be written.
            guard generation == currentGeneration else { return }
            states[chunk.id] = .failed(reason: "cancelled")
            return
        } catch {
            guard generation == currentGeneration else { return }
            states[chunk.id] = .failed(reason: "\(error)")
        }
    }

    // MARK: - Validation

    /// Synthesize with output validation.
    ///
    /// The backend can return HTTP 200 with truncated or entirely absent audio (see the
    /// spec's Known Issues). Comparing the returned duration against the character-count
    /// estimate is the only thing that makes that failure visible.
    ///
    /// Recovery is a recursive ladder, not a one-shot "retry once, split once" — measured
    /// behavior shows failures are intermittent and state-dependent (the same input,
    /// unchanged in size, succeeds in one run and fails in another), so a piece that fails
    /// is not necessarily doomed and deserves a full attempt budget at every size it's
    /// tried at, including after a split. At each level we attempt synthesis up to
    /// `maxRetries + 1` times; if every attempt at a level fails, the text is halved at a
    /// word boundary and each half is recursed into independently (with its own full
    /// attempt budget), up to `maxSplitDepth` levels deep. Halves are concatenated in
    /// order; only once the depth limit is exhausted does a piece give up, and its
    /// failure propagates up and fails the whole chunk.
    private func synthesizeValidated(chunk: Chunk, voice: String) async throws -> Data {
        try await synthesizeWithRecovery(text: chunk.text, voice: voice, depth: 0)
    }

    private func synthesizeWithRecovery(text: String,
                                        voice: String,
                                        depth: Int) async throws -> Data {
        var lastData = Data()
        var attempt = 0
        while attempt <= validation.maxRetries {
            try Task.checkCancellation()
            lastData = try await provider.synthesize(text: text, voice: voice,
                                                     speed: Self.synthesisSpeed)
            if isAcceptable(data: lastData, for: text) { return lastData }
            attempt += 1
        }

        // Every attempt at this level failed. Smaller inputs sit further inside the
        // backend's working range, and failures are intermittent, so halving and
        // recursing — with its own full attempt budget — is a real chance at recovery,
        // not just a formality.
        //
        // `splitInHalf` returns nil below four words, so a piece that short gives up here
        // without ever attempting a split. That is intentional, not an oversight: halving
        // a two- or three-word piece produces one- and two-word fragments, which the
        // backend prosodies differently and which carry so little text that the duration
        // estimate itself becomes noise — splitting there trades a visible failure for a
        // silent, unvalidatable one. The retry budget is the whole defense at that size.
        if depth < validation.maxSplitDepth, let halves = splitInHalf(text) {
            var combined = Data()
            // Halves are appended in document order. Order is invisible to the duration
            // check — reversed audio has exactly the right length — so it is guaranteed
            // here by construction and asserted directly in the tests.
            for piece in halves {
                try Task.checkCancellation()
                let data = try await synthesizeWithRecovery(text: piece, voice: voice,
                                                             depth: depth + 1)
                combined.append(data)
            }
            return combined
        }

        // Depth exhausted, or too short to split further: give up on this piece.
        if lastData.isEmpty {
            throw SpeechError.emptyAudio
        }
        throw SpeechError.shortAudio(
            expected: estimator.estimate(characterCount: text.count),
            got: estimator.duration(ofBytes: lastData.count, format: provider.outputFormat))
    }

    private func isAcceptable(data: Data, for text: String) -> Bool {
        guard !data.isEmpty else { return false }
        let expected = estimator.estimate(characterCount: text.count)
        guard expected > 0 else { return true }
        let got = estimator.duration(ofBytes: data.count, format: provider.outputFormat)
        return got / expected >= validation.minimumDurationRatio
    }

    /// Split at the word boundary nearest the middle. Returns nil when too short to split.
    private func splitInHalf(_ text: String) -> [String]? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return nil }
        let middle = words.count / 2
        return [words[..<middle].joined(separator: " "),
                words[middle...].joined(separator: " ")]
    }
}
