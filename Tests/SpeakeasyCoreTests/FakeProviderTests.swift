import Testing
import Foundation
@testable import SpeakeasyCore

@Test func fakeProducesAudioProportionalToText() async throws {
    let fake = FakeProvider()
    let data = try await fake.synthesize(text: String(repeating: "a", count: 154),
                                         voice: "af_bella", speed: 1.0)
    let seconds = DurationEstimator().duration(ofBytes: data.count, format: fake.outputFormat)
    #expect(abs(seconds - 10.0) < 0.1)
}

@Test func fakeCanReturnEmptyAudio() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.empty)
    let data = try await fake.synthesize(text: "hello there", voice: "v", speed: 1.0)
    #expect(data.isEmpty)
}

@Test func fakeCanReturnShortAudio() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.short(fraction: 0.25))
    let text = String(repeating: "a", count: 154)
    let data = try await fake.synthesize(text: text, voice: "v", speed: 1.0)
    let seconds = DurationEstimator().duration(ofBytes: data.count, format: fake.outputFormat)
    #expect(abs(seconds - 2.5) < 0.1)
}

@Test func fakeCanThrow() async {
    let fake = FakeProvider()
    await fake.setBehavior(.failing(.httpStatus(code: 500, body: "boom")))
    await #expect(throws: SpeechError.self) {
        try await fake.synthesize(text: "x", voice: "v", speed: 1.0)
    }
}

@Test func fakeRecordsCallsAndRespondsToCancellation() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.slow(seconds: 5))
    let task = Task { try await fake.synthesize(text: "x", voice: "v", speed: 1.0) }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    _ = try? await task.value
    #expect(await fake.cancelledCount == 1)
}

@Test func fakeListsVoices() async throws {
    let fake = FakeProvider()
    let voices = try await fake.listVoices()
    #expect(voices.contains(Voice(id: "af_bella", name: "af_bella")))
}
