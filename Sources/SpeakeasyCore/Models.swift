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

    public init(id: Int, text: String, estimatedDuration: TimeInterval) {
        self.id = id
        self.text = text
        self.estimatedDuration = estimatedDuration
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
    case formatMismatch(expected: AudioFormat, got: AudioFormat)
    case transport(String)
    case badResponse(String)
}
