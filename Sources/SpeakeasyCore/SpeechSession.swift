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
    public func speak(_ raw: String, voice: String, speed: Double) async -> Int {
        await cancelAll()

        currentGeneration += 1
        let generation = currentGeneration

        let prepared = preparer.prepare(raw)
        chunks = segmenter.segment(prepared)
        states = [:]
        for chunk in chunks { states[chunk.id] = .pending }

        startRendering(generation: generation, voice: voice, speed: speed)
        return generation
    }

    /// Cancels every in-flight render task and waits for each to actually stop before
    /// returning. Marking a task cancelled only flips a flag; the task's own suspension
    /// point (inside the provider, possibly on another actor) needs a scheduler tick to
    /// observe it and unwind. Returning before that happens would let a caller believe
    /// cancellation is complete when it is still in flight — races against a following
    /// `speak` are exactly what generations exist to prevent.
    public func cancelAll() async {
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
