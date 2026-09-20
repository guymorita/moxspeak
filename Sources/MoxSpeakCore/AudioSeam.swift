import Foundation

/// Makes consecutive chunks sound like one continuous utterance.
///
/// ## The problem this exists to solve
///
/// Kokoro pads every utterance it synthesizes with silence at both ends, and the padding
/// is large and nearly constant — measured on this engine across two voices and inputs
/// from 10 to 128 characters:
///
///     lead   374 – 452 ms
///     tail   476 – 666 ms
///
/// Concatenating two chunks therefore butts one utterance's tail against the next one's
/// lead, and **every chunk boundary becomes about a full second of dead air**. For
/// comparison, the pause Kokoro renders between two sentences *inside* a single chunk —
/// which is the engine's own idea of how long a sentence break should be — measures
/// 284 to 499 ms. So a seam was running two to three times longer than a sentence break,
/// at boundaries that are frequently not even sentence breaks.
///
/// That is what "it stops at awkward places" is. The chunking was never really the
/// problem; the silence stapled to each chunk was.
///
/// ## What it does instead
///
/// Strip the padding, then put back a gap chosen from what the text actually says. A
/// chunk that ends a sentence earns a sentence-length pause; one that ends at a comma
/// earns a short one; one the segmenter had to cut between two words of the same clause
/// earns none at all, because no speaker would pause there.
///
/// Trimming the lead also buys latency for free: chunk 0's ~445 ms of leading silence sat
/// between the hotkey and the first audible sound, inside a budget of half a second.
public struct AudioSeam: Sendable {

    public struct Options: Sendable {
        /// Amplitude below which a sample counts as silence, as a fraction of full scale.
        ///
        /// 0.3%, well under the ~1% used to *measure* the padding. Trimming and measuring
        /// want thresholds erring in opposite directions: a measurement that overshoots
        /// reports slightly too much silence, while a trim that overshoots eats the onset
        /// of the first word. Low floor plus the keep-margins below is the conservative
        /// combination.
        public var silenceFraction: Double = 0.003

        /// Silence deliberately left in front of the first sample and after the last.
        /// A hard cut at the exact onset clips quiet consonants and sounds clicky; 30 ms
        /// is below perception as a delay and enough to keep an onset intact.
        public var keepLead: TimeInterval = 0.03
        public var keepTail: TimeInterval = 0.03

        /// Gaps to insert after a chunk, by what its last character was.
        ///
        /// `sentence` sits in the middle of the 284–499 ms Kokoro itself renders between
        /// sentences, so a seam at a sentence break is indistinguishable from one the
        /// engine produced internally. `clause` is a comma's worth. `word` is zero:
        /// the segmenter only splits between words when a clause overran the character
        /// cap, and there is no pause there in speech.
        public var sentenceGap: TimeInterval = 0.35
        public var clauseGap: TimeInterval = 0.12
        public var wordGap: TimeInterval = 0

        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Trimming

    /// The same audio with its leading and trailing silence reduced to `keepLead` and
    /// `keepTail`.
    ///
    /// Returns the input untouched for anything this can't safely reason about: a
    /// non-16-bit or containerized format (the byte layout would be a guess), an odd byte
    /// count, or audio that is silent all the way through — trimming that to nothing would
    /// turn a chunk the validation ladder already accepted into an empty one.
    public func trim(_ data: Data, format: AudioFormat) -> Data {
        guard format.isRawPCM, format.bitDepth == 16, !data.isEmpty, data.count % 2 == 0
        else { return data }

        let floor = Int(Double(Int16.max) * options.silenceFraction)
        let sampleCount = data.count / 2

        let bounds: (first: Int, last: Int)? = data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var first: Int?
            for i in 0..<sampleCount where abs(Int(samples[i])) > floor { first = i; break }
            guard let start = first else { return nil }
            var last = start
            for i in stride(from: sampleCount - 1, through: start, by: -1)
            where abs(Int(samples[i])) > floor { last = i; break }
            return (start, last)
        }
        guard let bounds else { return data }

        let perChannelFrame = format.channels * 2
        // Clamped before the conversion to Int. `keepLead` is a public knob, and a value
        // that is negative, infinite, or merely absurd would otherwise reach `Int(_:)`,
        // which traps on non-finite input — a caller tuning a comfort setting should not
        // be able to crash synthesis. A margin wider than the audio is meaningless anyway;
        // it simply means "keep everything".
        let maxMargin = Double(sampleCount) / format.sampleRate
        func margin(_ seconds: TimeInterval) -> Int {
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return Int(min(seconds, maxMargin) * format.sampleRate) * format.channels
        }
        let lead = margin(options.keepLead)
        let tail = margin(options.keepTail)
        let from = max(0, bounds.first - lead)
        let through = min(sampleCount - 1, bounds.last + tail)
        guard from < through else { return data }

        // Byte offsets, snapped down to a frame boundary so a multi-channel format can
        // never be cut mid-frame and swap its channels for the rest of the chunk.
        var startByte = from * 2
        var endByte = (through + 1) * 2
        startByte -= startByte % perChannelFrame
        endByte -= endByte % perChannelFrame
        guard startByte < endByte, endByte <= data.count else { return data }
        return data.subdata(in: startByte..<endByte)
    }

    // MARK: - Gaps

    /// Digital silence, as bytes in this format.
    public func silence(seconds: TimeInterval, format: AudioFormat) -> Data {
        guard seconds > 0 else { return Data() }
        let frame = format.channels * (format.bitDepth / 8)
        var bytes = Int(seconds * Double(format.bytesPerSecond))
        bytes -= bytes % frame
        return bytes > 0 ? Data(count: bytes) : Data()
    }

    /// How long a pause belongs after a chunk ending in this text.
    public func gapSeconds(after text: String) -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return options.wordGap }
        if ".!?…".contains(last) { return options.sentenceGap }
        if ",;:—".contains(last) { return options.clauseGap }
        return options.wordGap
    }

    /// Trim a chunk and give it the pause its own punctuation earns. The convenience the
    /// session actually calls.
    public func join(_ data: Data, endingWith text: String, format: AudioFormat) -> Data {
        var audio = trim(data, format: format)
        audio.append(silence(seconds: gapSeconds(after: text), format: format))
        return audio
    }
}
