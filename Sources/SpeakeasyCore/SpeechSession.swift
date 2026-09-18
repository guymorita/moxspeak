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
    private let segmenter: Segmenter
    private let estimator: DurationEstimator
    private let validation: ValidationPolicy

    public private(set) var currentGeneration = 0
    public private(set) var chunks: [Chunk] = []

    private var states: [Int: ChunkState] = [:]
    private var renderTasks: [Task<Void, Never>] = []

    public init(provider: any SpeechProvider,
                preparer: TextPreparer = TextPreparer(),
                segmenter: Segmenter = Segmenter(),
                estimator: DurationEstimator = DurationEstimator(),
                validation: ValidationPolicy = ValidationPolicy()) {
        self.provider = provider
        self.preparer = preparer
        self.segmenter = segmenter
        self.estimator = estimator
        self.validation = validation
    }

    public func state(of index: Int) -> ChunkState {
        states[index] ?? .pending
    }

    /// Replaces whatever is playing. Returns the new generation.
    @discardableResult
    public func speak(_ raw: String, voice: String, speed: Double) -> Int {
        cancelAll()

        currentGeneration += 1
        let generation = currentGeneration

        let prepared = preparer.prepare(raw)
        chunks = segmenter.segment(prepared)
        states = [:]
        for chunk in chunks { states[chunk.id] = .pending }

        startRendering(generation: generation, voice: voice, speed: speed)
        return generation
    }

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
        for task in renderTasks { task.cancel() }
        renderTasks = []
    }

    /// Like `cancelAll()`, but waits for every cancelled task to actually finish before
    /// returning. Use this for shutdown, or anywhere the caller needs cancellation's
    /// effects to be fully settled — not on the `speak` hot path.
    public func cancelAllAndWait() async {
        let tasks = renderTasks
        renderTasks = []
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
    }

    /// Test and CLI helper: resolves once every render task has finished.
    public func waitForRenderComplete() async {
        let tasks = renderTasks
        for task in tasks { _ = await task.value }
    }

    // MARK: - Rendering

    /// Synthesis runs continuously ahead of playback, not one chunk ahead. At 13-20x
    /// realtime it outruns listening, which is what makes seeking feel instant.
    private func startRendering(generation: Int, voice: String, speed: Double) {
        for chunk in chunks {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.render(chunk: chunk,
                                   generation: generation,
                                   voice: voice,
                                   speed: speed)
            }
            renderTasks.append(task)
        }
    }

    private func render(chunk: Chunk, generation: Int, voice: String, speed: Double) async {
        guard generation == currentGeneration else { return }
        states[chunk.id] = .synthesizing

        do {
            let data = try await synthesizeValidated(chunk: chunk, voice: voice, speed: speed)
            // The generation may have advanced while this was in flight.
            guard generation == currentGeneration else { return }
            let duration = estimator.duration(ofBytes: data.count, format: provider.outputFormat)
            states[chunk.id] = .rendered(data: data, duration: duration)
        } catch is CancellationError {
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
    private func synthesizeValidated(chunk: Chunk,
                                     voice: String,
                                     speed: Double) async throws -> Data {
        try await synthesizeWithRecovery(text: chunk.text, voice: voice, speed: speed, depth: 0)
    }

    private func synthesizeWithRecovery(text: String,
                                        voice: String,
                                        speed: Double,
                                        depth: Int) async throws -> Data {
        var lastData = Data()
        var attempt = 0
        while attempt <= validation.maxRetries {
            try Task.checkCancellation()
            lastData = try await provider.synthesize(text: text, voice: voice, speed: speed)
            if isAcceptable(data: lastData, for: text) { return lastData }
            attempt += 1
        }

        // Every attempt at this level failed. Smaller inputs sit further inside the
        // backend's working range, and failures are intermittent, so halving and
        // recursing — with its own full attempt budget — is a real chance at recovery,
        // not just a formality.
        if depth < validation.maxSplitDepth, let halves = splitInHalf(text) {
            var combined = Data()
            for piece in halves {
                try Task.checkCancellation()
                let data = try await synthesizeWithRecovery(text: piece, voice: voice,
                                                             speed: speed, depth: depth + 1)
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
