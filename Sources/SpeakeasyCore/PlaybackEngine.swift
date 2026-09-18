import Foundation
import AVFoundation

/// Plays raw PCM through AVAudioEngine.
///
/// The TimePitch unit means playback speed changes are instant and pitch-corrected,
/// with no re-synthesis and no request to the engine. Playback speed and synthesis
/// speed are deliberately decoupled.
public final class PlaybackEngine: @unchecked Sendable {

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

    /// Playback rate. 1.0 is normal; pitch is preserved.
    public var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    public func start() throws {
        guard !engine.isRunning else { return }
        try engine.start()
        player.play()
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
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [pending] _ in
            pending.decrement()
        }
    }

    public func stop() {
        player.stop()
        engine.stop()
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
    public static func buffer(from data: Data, format: AudioFormat) -> AVAudioPCMBuffer? {
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
