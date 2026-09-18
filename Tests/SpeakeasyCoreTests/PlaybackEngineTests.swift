import Testing
import Foundation
import AVFoundation
@testable import SpeakeasyCore

@Test func convertsRawPCMBytesToABuffer() throws {
    // One second of silence: 48000 bytes at 24kHz 16-bit mono.
    let data = Data(count: 48000)
    let buffer = try #require(PlaybackEngine.buffer(from: data, format: .kokoroPCM))
    #expect(buffer.frameLength == 24000)
    #expect(buffer.format.channelCount == 1)
    #expect(buffer.format.sampleRate == 24000)
}

@Test func preservesSampleValues() throws {
    // Two frames: 0x0100 == 256, 0xFF7F == 32767 little-endian.
    var data = Data()
    data.append(contentsOf: [0x00, 0x01])
    data.append(contentsOf: [0xFF, 0x7F])
    let buffer = try #require(PlaybackEngine.buffer(from: data, format: .kokoroPCM))
    #expect(buffer.frameLength == 2)
    let channel = try #require(buffer.floatChannelData?[0])
    #expect(abs(channel[0] - (256.0 / 32768.0)) < 0.0001)
    #expect(abs(channel[1] - (32767.0 / 32768.0)) < 0.0001)
}

@Test func rejectsOddLengthData() {
    // 16-bit samples cannot come in odd byte counts.
    #expect(PlaybackEngine.buffer(from: Data(count: 3), format: .kokoroPCM) == nil)
}

@Test func emptyDataProducesNoBuffer() {
    #expect(PlaybackEngine.buffer(from: Data(), format: .kokoroPCM) == nil)
}

// MARK: - enqueue must never drop audio silently

@Test func enqueueThrowsOnAPartialFrame() throws {
    // An odd byte count is what a mid-sample truncation from the backend looks like.
    // Returning quietly here would lose the chunk inside the very component built to stop
    // audio being lost quietly.
    let engine = try PlaybackEngine(format: .kokoroPCM)
    #expect(throws: SpeechError.self) {
        try engine.enqueue(Data(count: 3))
    }
}

@Test func enqueueErrorNamesTheByteCountAndFrameSize() throws {
    let engine = try PlaybackEngine(format: .kokoroPCM)
    do {
        try engine.enqueue(Data(count: 3))
        Issue.record("expected enqueue to throw")
    } catch let error as SpeechError {
        guard case .badResponse(let message) = error else {
            Issue.record("expected .badResponse, got \(error)")
            return
        }
        #expect(message.contains("3"), "message must name the byte count: \(message)")
        #expect(message.contains("2"), "message must name the frame size: \(message)")
    }
}

@Test func enqueueThrowsOnEmptyData() throws {
    let engine = try PlaybackEngine(format: .kokoroPCM)
    #expect(throws: SpeechError.self) {
        try engine.enqueue(Data())
    }
}

@Test func enqueueAcceptsWholeFrames() throws {
    let engine = try PlaybackEngine(format: .kokoroPCM)
    try engine.enqueue(Data(count: 4800))   // 0.1s, a whole number of frames
}

// MARK: - init rejects formats it cannot actually play

@Test func initRejectsNon16BitFormats() {
    // Constructing fine and then playing total silence is worse than failing loudly:
    // `buffer(from:)` only decodes signed 16-bit PCM.
    for depth in [8, 24, 32] {
        let format = AudioFormat(sampleRate: 24000, channels: 1, bitDepth: depth, isRawPCM: true)
        #expect(throws: SpeechError.self, "bit depth \(depth) must be rejected") {
            _ = try PlaybackEngine(format: format)
        }
    }
}

@Test func initRejectsDegenerateChannelAndRateValues() {
    #expect(throws: SpeechError.self) {
        _ = try PlaybackEngine(format: AudioFormat(sampleRate: 24000, channels: 0,
                                                   bitDepth: 16, isRawPCM: true))
    }
    #expect(throws: SpeechError.self) {
        _ = try PlaybackEngine(format: AudioFormat(sampleRate: 0, channels: 1,
                                                   bitDepth: 16, isRawPCM: true))
    }
}

@Test func initAcceptsThe16BitKokoroFormat() throws {
    _ = try PlaybackEngine(format: .kokoroPCM)
}

// MARK: - Playback speed is a playback concern (C1)

@Test func playbackRateIsSettableAndIndependentOfSynthesis() async throws {
    // --speed lands here, on TimePitch, not on the synthesis request. It is instant,
    // pitch-corrected, and needs no re-synthesis, so changing it must not touch the
    // provider at all.
    let engine = try PlaybackEngine(format: .kokoroPCM)
    #expect(engine.rate == 1.0, "default playback rate is 1.0")

    for rate: Float in [0.5, 1.0, 1.75, 2.0] {
        engine.rate = rate
        #expect(engine.rate == rate)
    }

    // Synthesis is untouched by any of that: the session never varies speed.
    let fake = FakeProvider()
    let session = SpeechSession(provider: fake)
    engine.rate = 2.0
    _ = await session.speak("A single short sentence here.", voice: "v")
    await session.waitForRenderComplete()

    guard case .rendered(let data, _) = await session.state(of: 0) else {
        Issue.record("expected chunk 0 to render")
        return
    }
    // The audio is full length for the text, exactly as if the rate had never been set.
    let expected = DurationEstimator().estimate(characterCount: "A single short sentence here.".count)
    let got = DurationEstimator().duration(ofBytes: data.count, format: .kokoroPCM)
    #expect(abs(got - expected) < 0.05)
    #expect(engine.rate == 2.0, "setting playback rate survives synthesis")
}
