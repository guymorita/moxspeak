import Foundation

/// Converts between character counts, wall-clock seconds of speech, and audio byte counts.
///
/// The characters-per-second constant is measured, not theoretical: 15.4 chars/sec,
/// observed range 14.3-15.6 against Kokoro-FastAPI on an M2 Max. See the spec's
/// "Measured baseline" section. It is configurable because it is an engine property.
public struct DurationEstimator: Sendable {
    public static let defaultCharsPerSecond: Double = 15.4

    public let charsPerSecond: Double

    public init(charsPerSecond: Double = DurationEstimator.defaultCharsPerSecond) {
        precondition(charsPerSecond > 0, "charsPerSecond must be positive")
        self.charsPerSecond = charsPerSecond
    }

    /// Predicted speech duration for text of this length, before synthesis.
    public func estimate(characterCount: Int) -> TimeInterval {
        guard characterCount > 0 else { return 0 }
        return Double(characterCount) / charsPerSecond
    }

    /// Actual duration of received audio. Exact for raw PCM.
    public func duration(ofBytes byteCount: Int, format: AudioFormat) -> TimeInterval {
        guard byteCount > 0, format.bytesPerSecond > 0 else { return 0 }
        return Double(byteCount) / Double(format.bytesPerSecond)
    }
}
