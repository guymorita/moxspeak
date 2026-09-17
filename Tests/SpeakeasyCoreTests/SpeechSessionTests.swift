import Testing
import Foundation
@testable import SpeakeasyCore

private func makeSession(provider: some SpeechProvider,
                         policy: SpeechSession.ValidationPolicy = .init()) -> SpeechSession {
    SpeechSession(provider: provider,
                  preparer: TextPreparer(),
                  segmenter: Segmenter(),
                  estimator: DurationEstimator(),
                  validation: policy)
}

private let article = String(
    repeating: "This is a sentence of ordinary length that will be chunked. ", count: 12)

@Test func rendersEveryChunk() async {
    let session = makeSession(provider: FakeProvider())
    _ = await session.speak(article, voice: "af_bella", speed: 1.0)
    await session.waitForRenderComplete()

    let chunks = await session.chunks
    #expect(chunks.count > 1)
    for chunk in chunks {
        guard case .rendered = await session.state(of: chunk.id) else {
            Issue.record("chunk \(chunk.id) not rendered")
            return
        }
    }
}

@Test func advancesGenerationOnEachSpeak() async {
    let session = makeSession(provider: FakeProvider())
    let first = await session.speak("Hello there.", voice: "v", speed: 1.0)
    let second = await session.speak("Different text.", voice: "v", speed: 1.0)
    #expect(second > first)
}

@Test func staleResponsesAreDiscardedAfterReplace() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.slow(seconds: 2))
    let session = makeSession(provider: fake)

    _ = await session.speak(article, voice: "v", speed: 1.0)
    try await Task.sleep(for: .milliseconds(50))

    await fake.setBehavior(.normal)
    let newGeneration = await session.speak("Completely different text.", voice: "v", speed: 1.0)
    await session.waitForRenderComplete()

    // The new generation's chunks are present and the old work committed nothing.
    #expect(await session.currentGeneration == newGeneration)
    let chunks = await session.chunks
    #expect(chunks.count == 1)
    #expect(chunks[0].text == "Completely different text.")
}

@Test func cancelAllStopsInFlightWork() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.slow(seconds: 5))
    let session = makeSession(provider: fake)

    _ = await session.speak(article, voice: "v", speed: 1.0)
    try await Task.sleep(for: .milliseconds(50))
    await session.cancelAll()

    #expect(await fake.cancelledCount >= 1)
}

@Test func emptyInputProducesNoChunks() async {
    let session = makeSession(provider: FakeProvider())
    _ = await session.speak("   ", voice: "v", speed: 1.0)
    #expect(await session.chunks.isEmpty)
}

@Test func appliesTextPreparationBeforeSegmenting() async {
    let session = makeSession(provider: FakeProvider())
    _ = await session.speak("## A **heading**", voice: "v", speed: 1.0)
    let chunks = await session.chunks
    #expect(chunks.first?.text == "A heading")
}
