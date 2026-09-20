import Foundation
import Testing
@testable import MoxSpeakCore

/// `AudioSeam` is what stands between "several chunks" and "one continuous utterance",
/// so these tests are written against synthetic audio with padding of a known size —
/// the real engine's padding is measured in `SeamProbeTests`, which needs the model.
@Suite struct AudioSeamTests {

    static let format = AudioFormat.kokoroPCM

    /// `lead` seconds of digital silence, `tone` seconds of full-scale square wave, then
    /// `tail` seconds of silence. Stands in for one Kokoro utterance.
    static func padded(lead: TimeInterval, tone: TimeInterval, tail: TimeInterval) -> Data {
        func samples(_ seconds: TimeInterval, value: (Int) -> Int16) -> Data {
            let count = Int(seconds * format.sampleRate)
            var out = Data(capacity: count * 2)
            for i in 0..<count { withUnsafeBytes(of: value(i).littleEndian) { out.append(contentsOf: $0) } }
            return out
        }
        var data = samples(lead) { _ in 0 }
        data.append(samples(tone) { $0 % 2 == 0 ? 12000 : -12000 })
        data.append(samples(tail) { _ in 0 })
        return data
    }

    static func seconds(_ data: Data) -> TimeInterval {
        Double(data.count) / Double(format.bytesPerSecond)
    }

    // MARK: - Trimming

    @Test func trimReducesPaddingToTheKeepMargins() {
        let seam = AudioSeam()
        let audio = Self.padded(lead: 0.45, tone: 1.0, tail: 0.55)
        let trimmed = seam.trim(audio, format: Self.format)

        // 1.0s of tone, plus 30ms kept at each end.
        let expected = 1.0 + seam.options.keepLead + seam.options.keepTail
        #expect(abs(Self.seconds(trimmed) - expected) < 0.01,
                Comment(rawValue: "trimmed to \(Self.seconds(trimmed))s, expected ~\(expected)s"))
        #expect(Self.seconds(audio) > Self.seconds(trimmed))
    }

    /// The whole point: two trimmed chunks butted together must not stack their padding.
    @Test func twoChunksNoLongerStackASecondOfSilence() {
        let seam = AudioSeam()
        let first = Self.padded(lead: 0.45, tone: 1.0, tail: 0.55)
        let second = Self.padded(lead: 0.45, tone: 1.0, tail: 0.55)

        let naive = Self.seconds(first) + Self.seconds(second)
        let joined = Self.seconds(seam.join(first, endingWith: "a clause,", format: Self.format))
                   + Self.seconds(seam.trim(second, format: Self.format))

        // Untreated, the seam alone is tail + lead = 1.0s. Treated, it is 30ms + a 120ms
        // clause gap + 30ms.
        #expect(naive - joined > 0.9,
                Comment(rawValue: "saved only \(naive - joined)s at the seam"))
    }

    /// Trimming must never turn a chunk the validation ladder accepted into an empty one.
    @Test func silenceAllTheWayThroughIsLeftAlone() {
        let silent = Self.padded(lead: 0.5, tone: 0, tail: 0.5)
        #expect(AudioSeam().trim(silent, format: Self.format) == silent)
    }

    /// The byte layout of anything else is a guess, and guessing produces noise.
    @Test func unknownFormatsArePassedThroughUntouched() {
        let audio = Self.padded(lead: 0.4, tone: 0.5, tail: 0.4)
        let mp3 = AudioFormat(sampleRate: 24000, channels: 1, bitDepth: 16, isRawPCM: false)
        let float = AudioFormat(sampleRate: 24000, channels: 1, bitDepth: 32, isRawPCM: true)
        #expect(AudioSeam().trim(audio, format: mp3) == audio)
        #expect(AudioSeam().trim(audio, format: float) == audio)
        #expect(AudioSeam().trim(Data([1, 2, 3]), format: Self.format) == Data([1, 2, 3]))
    }

    /// `keepLead` is a public knob and reaches `Int(_:)`, which traps on non-finite
    /// input. Found by a probe that set it to `.infinity` to stand in for "never trim";
    /// the process died instead of producing a measurement.
    @Test func absurdKeepMarginsCannotCrashSynthesis() {
        let audio = Self.padded(lead: 0.4, tone: 0.5, tail: 0.4)
        for value in [Double.infinity, -Double.infinity, .nan, -1, 1_000_000] {
            var options = AudioSeam.Options()
            options.keepLead = value
            options.keepTail = value
            let out = AudioSeam(options: options).trim(audio, format: Self.format)
            #expect(!out.isEmpty)
            #expect(out.count <= audio.count)
        }
    }

    @Test func aChunkWithNoRoomToTrimSurvives() {
        let tiny = Self.padded(lead: 0.005, tone: 0.01, tail: 0.005)
        #expect(!AudioSeam().trim(tiny, format: Self.format).isEmpty)
    }

    // MARK: - Gaps

    /// The gap is chosen by what a speaker would do, not by what the engine padded.
    @Test func theGapIsSizedByThePunctuationTheChunkEndsOn() {
        let seam = AudioSeam()
        #expect(seam.gapSeconds(after: "He stopped there.") == seam.options.sentenceGap)
        #expect(seam.gapSeconds(after: "Wait — really?") == seam.options.sentenceGap)
        #expect(seam.gapSeconds(after: "the first part,") == seam.options.clauseGap)
        #expect(seam.gapSeconds(after: "two things: ") == seam.options.clauseGap)
        // The case that started this: cut between two words of one clause. No speaker
        // pauses there, so neither do we.
        #expect(seam.gapSeconds(after: "stopping at lots of") == seam.options.wordGap)
        #expect(seam.gapSeconds(after: "") == seam.options.wordGap)
    }

    /// A sentence seam should be indistinguishable from the pause Kokoro renders between
    /// two sentences inside one chunk, which measured 284–499 ms.
    @Test func theSentenceGapMatchesWhatTheEngineDoesInternally() {
        let gap = AudioSeam().options.sentenceGap
        #expect(gap >= 0.284 && gap <= 0.499)
    }

    @Test func silenceIsFrameAlignedAndTheRightLength() {
        let seam = AudioSeam()
        let quarter = seam.silence(seconds: 0.25, format: Self.format)
        #expect(quarter.count % (Self.format.channels * Self.format.bitDepth / 8) == 0)
        #expect(abs(Self.seconds(quarter) - 0.25) < 0.001)
        #expect(quarter.allSatisfy { $0 == 0 })
        #expect(seam.silence(seconds: 0, format: Self.format).isEmpty)
        #expect(seam.silence(seconds: -1, format: Self.format).isEmpty)
    }

    @Test func joinIsTrimThenGap() {
        let seam = AudioSeam()
        let audio = Self.padded(lead: 0.45, tone: 1.0, tail: 0.55)
        let joined = seam.join(audio, endingWith: "a sentence.", format: Self.format)
        let expected = Self.seconds(seam.trim(audio, format: Self.format)) + seam.options.sentenceGap
        #expect(abs(Self.seconds(joined) - expected) < 0.001)
    }
}

/// The seam has to be applied by `SpeechSession`, not merely to exist in Core.
@Suite struct SessionSeamTests {

    static func seconds(_ data: Data) -> TimeInterval {
        Double(data.count) / Double(AudioFormat.kokoroPCM.bytesPerSecond)
    }

    static func rendered(_ session: SpeechSession, _ id: Int) async -> Data? {
        if case .rendered(let data, _) = await session.state(of: id) { return data }
        return nil
    }

    /// Two sentences, two chunks, engine padding on both. Without the seam the boundary
    /// carries the first chunk's tail plus the second's lead — a full second of nothing.
    ///
    /// Asserted as "nearly all the padding is gone", not "shorter than synthesized": the
    /// fake's byte counts round down, so a merely-shorter assertion passes even with the
    /// seam removed entirely, which is how the first version of this test was useless.
    @Test func theSessionStripsEnginePaddingFromEveryChunk() async throws {
        let lead = 0.42, tail = 0.57
        let provider = FakeProvider()
        await provider.setBehavior(.padded(lead: lead, tail: tail))
        let seam = AudioSeam()
        let session = SpeechSession(provider: provider,
                                    segmenter: Segmenter(options: Segmenter.Options(providerCap: 60)),
                                    seam: seam)
        _ = await session.speak("The first sentence runs on for a while. The second one does too.",
                                voice: "af_bella")
        await session.waitForRenderComplete()

        let chunks = await session.chunks
        #expect(chunks.count >= 2, "need at least two chunks to have a seam")

        for chunk in chunks {
            let data = try #require(await Self.rendered(session, chunk.id))
            let spoken = Self.seconds(data) - Self.leadingSilence(data) - Self.trailingSilence(data)
            let asSynthesized = Self.seconds(data)

            // What survives at the edges must be the keep margins plus at most the
            // punctuation gap — never the engine's ~1s of padding.
            let allowed = seam.options.keepLead + seam.options.keepTail
                        + seam.options.sentenceGap + 0.02
            #expect(asSynthesized - spoken < allowed,
                    Comment(rawValue: "chunk \(chunk.id) carries "
                                      + "\(asSynthesized - spoken)s of silence at its edges, "
                                      + "against an allowance of \(allowed)s"))
            #expect(asSynthesized - spoken < lead + tail,
                    Comment(rawValue: "chunk \(chunk.id) kept the engine's full padding"))
        }
    }

    /// A chunk that ends a sentence keeps a sentence-sized pause; the last chunk gets
    /// none, because there is nothing after it to be continuous with.
    @Test func theGapComesFromTheTextAndTheLastChunkHasNone() async throws {
        let provider = FakeProvider()
        await provider.setBehavior(.padded(lead: 0.42, tail: 0.57))
        let seam = AudioSeam()
        let session = SpeechSession(provider: provider,
                                    segmenter: Segmenter(options: Segmenter.Options(providerCap: 60)),
                                    seam: seam)
        _ = await session.speak("The first sentence runs on for a while. The second one does too.",
                                voice: "af_bella")
        await session.waitForRenderComplete()

        let chunks = await session.chunks
        let last = try #require(await Self.rendered(session, chunks[chunks.count - 1].id))
        let trailing = Self.trailingSilence(last)
        #expect(trailing < seam.options.keepTail + 0.01,
                Comment(rawValue: "the final chunk ended with \(trailing)s of silence"))

        let first = try #require(await Self.rendered(session, chunks[0].id))
        let firstTrailing = Self.trailingSilence(first)
        #expect(firstTrailing > seam.options.keepTail,
                Comment(rawValue: "a non-final chunk got no gap at all (\(firstTrailing)s)"))
    }

    static func trailingSilence(_ data: Data) -> TimeInterval {
        let samples: [Int16] = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        guard let last = samples.lastIndex(where: { abs(Int($0)) > 98 }) else { return 0 }
        return Double(samples.count - 1 - last) / AudioFormat.kokoroPCM.sampleRate
    }
}

extension SessionSeamTests {
    static func leadingSilence(_ data: Data) -> TimeInterval {
        let samples: [Int16] = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        guard let first = samples.firstIndex(where: { abs(Int($0)) > 98 }) else { return 0 }
        return Double(first) / AudioFormat.kokoroPCM.sampleRate
    }
}
