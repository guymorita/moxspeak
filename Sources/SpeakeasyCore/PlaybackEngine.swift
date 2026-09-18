import Foundation
import AVFoundation

/// Plays raw PCM through AVAudioEngine.
///
/// The TimePitch unit means playback speed changes are instant and pitch-corrected,
/// with no re-synthesis and no request to the engine. Playback speed and synthesis
/// speed are deliberately decoupled.
///
/// ## Why this is `@MainActor`
///
/// `AVAudioEngine` is not documented thread-safe for graph mutation (`attach`/`connect`)
/// or transport (`start`/`stop`/`pause`/`scheduleBuffer`). The previous
/// `@unchecked Sendable` annotation only ever protected `PendingCount`; `engine`,
/// `player` and `timePitch` were reachable from any thread with no synchronization at
/// all. That was survivable while the single caller was a CLI that touched the engine
/// from one place, and stops being survivable the moment a UI drives it from menu
/// actions, hotkey callbacks and a playback pump at once.
///
/// Pinning the whole type to the main actor lets the compiler prove there is no
/// concurrent graph access, and costs nothing: every caller (CLI top-level code, the
/// menu bar app) already runs there. `PendingCount` stays `NSLock`-protected because its
/// completion handler genuinely does fire on an audio thread, outside any actor.
@MainActor
public final class PlaybackEngine {

    /// Thread-safe because the completion handler fires on an AVAudioEngine thread.
    private final class PendingCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func decrement() { lock.lock(); value -= 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format: AudioFormat
    private let processingFormat: AVAudioFormat
    private let pending = PendingCount()

    public init(format: AudioFormat) throws {
        // Reject up front anything `buffer(from:)` cannot decode. Without this the engine
        // constructs happily, every `enqueue` hands it audio it cannot convert, and the
        // user hears total silence with nothing reported anywhere.
        guard format.bitDepth == 16 else {
            throw SpeechError.badResponse(
                "unsupported bit depth \(format.bitDepth); only signed 16-bit PCM is decoded")
        }
        guard format.channels > 0, format.sampleRate > 0 else {
            throw SpeechError.badResponse(
                "invalid audio format: \(format.channels) channels at \(format.sampleRate) Hz")
        }

        self.format = format
        guard let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: format.sampleRate,
                                             channels: AVAudioChannelCount(format.channels),
                                             interleaved: false) else {
            throw SpeechError.badResponse("unsupported audio format")
        }
        self.processingFormat = processing

        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: processing)
        engine.connect(timePitch, to: engine.mainMixerNode, format: processing)
    }

    /// Sane user-facing bounds for `rate`. `AVAudioUnitTimePitch.rate` itself accepts
    /// 1/32...32, but nothing north of 3x or south of 0.5x is a rate anyone actually
    /// wants — and a rate of exactly 0 is actively dangerous: the scheduled buffer's
    /// completion callback never fires at 0x, so `PlaybackEngine.waitForDrain()` (and
    /// anything that awaits it, like the CLI) hangs forever. Clamping here, in the
    /// setter, protects every caller — CLI today, Plan 2's UI tomorrow — rather than
    /// relying on each call site to remember to check.
    public nonisolated static let rateRange: ClosedRange<Float> = 0.5...3.0

    /// Playback rate. 1.0 is normal; pitch is preserved. Values outside `rateRange` are
    /// clamped rather than accepted as-is.
    public var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = min(max(newValue, Self.rateRange.lowerBound), Self.rateRange.upperBound) }
    }

    /// True between a `pause()` and the next `resume()`, `start()` or `stop()`.
    ///
    /// This is the engine's own record of intent rather than a reading of
    /// `AVAudioPlayerNode.isPlaying`, which also goes false when the queue simply runs
    /// dry — a paused engine and an idle one are different things to a caller, and only
    /// one of them resumes.
    public private(set) var isPaused = false

    /// Starts the transport. A start is always a fresh one: anything scheduled before it
    /// plays, and a `pause()` issued while stopped is not carried across.
    public func start() throws {
        guard !engine.isRunning else { return }
        try engine.start()
        player.play()
        isPaused = false
    }

    /// Suspends playback with the queue intact. Idempotent; a second call does nothing.
    ///
    /// `AVAudioPlayerNode.pause()` keeps every scheduled buffer and the current playback
    /// position, so `resume()` picks up mid-word rather than restarting the chunk. Note
    /// that `waitForDrain()` will not return while paused — the pending count only falls
    /// as buffers are actually heard — which is the honest answer to "has this been
    /// played yet", not a deadlock.
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        // No-op unless the transport is actually running; pausing a node that was never
        // started is meaningless to AVAudioEngine but meaningful to the caller's state.
        if engine.isRunning { player.pause() }
    }

    /// Resumes from exactly where `pause()` left off. Idempotent when not paused.
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        if engine.isRunning { player.play() }
    }

    /// Schedules one chunk of raw PCM for playback.
    ///
    /// Throws rather than dropping unconvertible bytes. A byte count that is not a whole
    /// number of frames is exactly what a mid-sample truncation from the backend looks
    /// like, and silently skipping it would lose audio inside the one component built to
    /// stop audio being lost silently. No chunk is ever discarded without a caller hearing
    /// about it.
    public func enqueue(_ data: Data) throws {
        guard let buffer = Self.buffer(from: data, format: format) else {
            let bytesPerFrame = (format.bitDepth / 8) * format.channels
            throw SpeechError.badResponse(
                "cannot decode \(data.count) bytes as PCM: expected a non-zero multiple of "
                + "\(bytesPerFrame) bytes per frame")
        }
        pending.increment()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
                              completionHandler: Self.decrementHandler(for: pending))
    }

    /// Builds the buffer-completion handler outside any actor.
    ///
    /// This indirection is load-bearing, not style. `scheduleBuffer`'s handler is not
    /// declared `@Sendable`, so a closure literal written inline in `enqueue` inherits
    /// this type's `@MainActor` isolation — and AVAudioEngine then calls it from a
    /// render thread, which the concurrency runtime flags as a data race at runtime
    /// ("@MainActor function ... was not called on the main thread"). Forming the
    /// closure in a `nonisolated` context gives it no isolation to violate. It touches
    /// only `PendingCount`, which is `NSLock`-protected precisely because it is the one
    /// piece of this class that legitimately lives on the audio thread.
    private nonisolated static func decrementHandler(
        for pending: PendingCount
    ) -> AVAudioPlayerNodeCompletionHandler {
        { _ in pending.decrement() }
    }

    public func stop() {
        player.stop()
        engine.stop()
        isPaused = false
    }

    /// Waits until everything scheduled has actually been heard, not merely handed to
    /// the renderer. Driven by per-buffer completion callbacks rather than polling
    /// `player.isPlaying`/`lastRenderTime`, which can read as "done" before playback has
    /// even started and would truncate the tail of the last chunk.
    public func waitForDrain() async {
        while pending.current > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Converts raw interleaved signed 16-bit little-endian samples to a float buffer.
    public nonisolated static func buffer(from data: Data, format: AudioFormat) -> AVAudioPCMBuffer? {
        guard format.bitDepth == 16, !data.isEmpty else { return nil }
        let bytesPerFrame = (format.bitDepth / 8) * format.channels
        guard data.count % bytesPerFrame == 0 else { return nil }

        let frameCount = data.count / bytesPerFrame
        guard let avFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: format.sampleRate,
                                           channels: AVAudioChannelCount(format.channels),
                                           interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: avFormat,
                                            frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                for channel in 0..<format.channels {
                    let sample = Int16(littleEndian: samples[frame * format.channels + channel])
                    channels[channel][frame] = Float(sample) / 32768.0
                }
            }
        }
        return buffer
    }
}
