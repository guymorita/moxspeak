import Foundation

public struct AudioFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let bitDepth: Int
    /// True when bytes arrive headerless (raw samples), false when wrapped in a container.
    public let isRawPCM: Bool

    public init(sampleRate: Double, channels: Int, bitDepth: Int, isRawPCM: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.isRawPCM = isRawPCM
    }

    public var bytesPerSecond: Int {
        Int(sampleRate) * channels * (bitDepth / 8)
    }

    /// Kokoro-FastAPI `response_format: "pcm"` — raw headerless signed 16-bit LE mono.
    public static let kokoroPCM = AudioFormat(
        sampleRate: 24000, channels: 1, bitDepth: 16, isRawPCM: true
    )
}

public struct Voice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Chunk: Equatable, Sendable, Identifiable {
    public let id: Int
    public let text: String
    public let estimatedDuration: TimeInterval

    /// This chunk's span in the prepared text that was handed to `Segmenter.segment`,
    /// in `Character` units: `sourceStart..<sourceEnd`. Integer offsets rather than
    /// `Range<String.Index>` because they're trivial to reason about and to serialize,
    /// and `String.Index` from one string isn't valid against another.
    ///
    /// Not always exactly `text.count` characters wide: packing joins units with a
    /// synthetic single space that isn't always literally present at that seam in the
    /// source (see `Segmenter`'s known dropped-space case), so `sourceEnd - sourceStart`
    /// can differ slightly from `text.count`. What's guaranteed is that this chunk's
    /// content was drawn only from `[sourceStart, sourceEnd)` of the prepared text.
    public let sourceStart: Int
    public let sourceEnd: Int

    /// Start of each sentence contained in this chunk, as a `Character` offset relative
    /// to this chunk's own `text` (not the source). A chunk usually holds several
    /// sentences; a sentence that started in an earlier chunk and merely continues here
    /// (because it was hard-split across a chunk boundary) is NOT listed again — only
    /// actual sentence starts are.
    public let sentenceOffsets: [Int]

    /// True when a paragraph break followed this chunk in the source.
    ///
    /// Carried all the way to `AudioSeam`, which gives it a longer pause than a sentence
    /// gets. Without it a new paragraph is acoustically identical to the next sentence,
    /// and a reader cannot hear the shape of what they are listening to.
    public let endsParagraph: Bool

    public init(id: Int, text: String, estimatedDuration: TimeInterval,
                sourceStart: Int, sourceEnd: Int, sentenceOffsets: [Int],
                endsParagraph: Bool = false) {
        self.endsParagraph = endsParagraph
        self.id = id
        self.text = text
        self.estimatedDuration = estimatedDuration
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.sentenceOffsets = sentenceOffsets
    }

    public var characterCount: Int { text.count }
}

public enum ChunkState: Sendable {
    case pending
    case synthesizing
    case rendered(data: Data, duration: TimeInterval)
    case failed(reason: String)
}

public enum SpeechError: Error, Equatable, Sendable {
    case httpStatus(code: Int, body: String)
    case emptyAudio
    case shortAudio(expected: TimeInterval, got: TimeInterval)
    /// Reserved. Nothing throws this yet: `SpeechProvider.outputFormat` is trusted rather
    /// than checked against responses. It is kept in place for the response-format check
    /// deferred to a later plan.
    case formatMismatch(expected: AudioFormat, got: AudioFormat)
    case transport(String)
    case badResponse(String)
}
