import AVFoundation
import Foundation
import Testing
@testable import MoxSpeakCore

/// Position and seeking. `AVAudioPlayerNode` has no seek, so moving within a reading means
/// stopping it and re-scheduling the tail — and everything that can go wrong with that is
/// bookkeeping.
@MainActor
@Suite struct SeekTests {

    static let format = AudioFormat.kokoroPCM

    /// `seconds` of a recognisable ramp, so a slice can be checked for starting in the
    /// right place rather than merely being the right length.
    static func pcm(seconds: Double, startingAt first: Int16 = 0) -> Data {
        let frames = Int(seconds * format.sampleRate)
        var data = Data(capacity: frames * 2)
        for i in 0..<frames {
            let value = Int16(truncatingIfNeeded: Int(first) &+ i)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - Duration

    @Test func durationIsWhatHasActuallyBeenEnqueued() throws {
        let engine = try PlaybackEngine(format: Self.format)
        #expect(engine.duration == 0)

        try engine.enqueue(Self.pcm(seconds: 2))
        #expect(abs(engine.duration - 2) < 0.01)

        try engine.enqueue(Self.pcm(seconds: 3))
        #expect(abs(engine.duration - 5) < 0.01,
                Comment(rawValue: "duration \(engine.duration)"))
    }

    /// Duration is in the source timeline, not wall clock. Somebody scrubbing a
    /// two-minute article expects two minutes whatever speed it is being read at, and
    /// Now Playing applies the rate itself.
    @Test func durationIgnoresPlaybackRate() throws {
        let engine = try PlaybackEngine(format: Self.format)
        try engine.enqueue(Self.pcm(seconds: 4))
        let atNormalSpeed = engine.duration
        engine.rate = 2.0
        #expect(engine.duration == atNormalSpeed)
    }

    @Test func stopClearsTheTimeline() throws {
        let engine = try PlaybackEngine(format: Self.format)
        try engine.enqueue(Self.pcm(seconds: 3))
        #expect(engine.duration > 0)
        engine.stop()
        #expect(engine.duration == 0)
        #expect(engine.elapsed == 0)
    }

    // MARK: - Seeking

    /// Seeking with nothing enqueued must not crash or move anywhere.
    @Test func seekingAnEmptyTimelineDoesNothing() throws {
        let engine = try PlaybackEngine(format: Self.format)
        engine.seek(to: 10)
        #expect(engine.elapsed == 0)
        #expect(engine.duration == 0)
    }

    /// Out-of-range targets clamp rather than throwing or landing past the end. A drag to
    /// the far right of a scrubber, or a skip-back at the very start, produce exactly
    /// these.
    @Test func seekingClampsToWhatExists() throws {
        let engine = try PlaybackEngine(format: Self.format)
        try engine.enqueue(Self.pcm(seconds: 5))

        engine.seek(to: -30)
        #expect(engine.elapsed >= 0)

        engine.seek(to: 9_999)
        #expect(engine.elapsed <= engine.duration + 0.01,
                Comment(rawValue: "landed at \(engine.elapsed) of \(engine.duration)"))
    }

    @Test func seekingLandsWhereItWasAsked() throws {
        let engine = try PlaybackEngine(format: Self.format)
        try engine.enqueue(Self.pcm(seconds: 4))
        try engine.enqueue(Self.pcm(seconds: 4))

        engine.seek(to: 6)
        #expect(abs(engine.elapsed - 6) < 0.05,
                Comment(rawValue: "elapsed \(engine.elapsed)"))
    }

    /// Somebody who pauses, drags the scrubber, then presses play expects the drag to
    /// have taken and the transport to still read as paused.
    @Test func seekingWhilePausedStaysPausedAndStillMoves() throws {
        let engine = try PlaybackEngine(format: Self.format)
        try engine.enqueue(Self.pcm(seconds: 8))
        try engine.start()
        engine.pause()
        #expect(engine.isPaused)

        engine.seek(to: 5)
        #expect(engine.isPaused, "seeking resumed playback behind the user's back")
        #expect(abs(engine.elapsed - 5) < 0.05)
        engine.stop()
    }

    // MARK: - Slicing

    /// The tail of a buffer has to start at the right sample, not merely be the right
    /// length — an off-by-one here is a click, or a word clipped in half.
    @Test func aSliceStartsAtTheFrameAskedFor() throws {
        let data = Self.pcm(seconds: 0.01)
        let buffer = try #require(PlaybackEngine.buffer(from: data, format: Self.format))
        let offset: AVAudioFrameCount = 40
        let tail = try #require(PlaybackEngine.slice(buffer, from: offset))

        #expect(tail.frameLength == buffer.frameLength - offset)
        let original = try #require(buffer.floatChannelData)
        let sliced = try #require(tail.floatChannelData)
        for i in 0..<10 {
            #expect(abs(sliced[0][i] - original[0][Int(offset) + i]) < 1e-6,
                    Comment(rawValue: "sample \(i) does not match"))
        }
    }

    @Test func slicingAtOrPastTheEndYieldsNothing() throws {
        let buffer = try #require(PlaybackEngine.buffer(from: Self.pcm(seconds: 0.01),
                                                        format: Self.format))
        #expect(PlaybackEngine.slice(buffer, from: buffer.frameLength) == nil)
        #expect(PlaybackEngine.slice(buffer, from: buffer.frameLength + 100) == nil)
    }
}
