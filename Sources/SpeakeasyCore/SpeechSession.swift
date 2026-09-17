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
        /// The backend silently truncates; see the spec's Known Issues.
        public var minimumDurationRatio: Double = 0.6
        public var maxRetries: Int = 1
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

    /// Overridden in Task 8 to add retry-then-split recovery.
    fileprivate func synthesizeValidated(chunk: Chunk,
                                         voice: String,
                                         speed: Double) async throws -> Data {
        try await provider.synthesize(text: chunk.text, voice: voice, speed: speed)
    }
}
