import Testing
import Foundation
@testable import SpeakeasyCore

@Test func estimatesFromCharacterCount() {
    let e = DurationEstimator()
    // 154 chars at 15.4 chars/sec == 10 seconds
    #expect(abs(e.estimate(characterCount: 154) - 10.0) < 0.001)
}

@Test func measuresDurationFromPCMBytes() {
    let e = DurationEstimator()
    // 48000 bytes == 1 second of 24kHz 16-bit mono
    #expect(e.duration(ofBytes: 48000, format: .kokoroPCM) == 1.0)
    #expect(e.duration(ofBytes: 24000, format: .kokoroPCM) == 0.5)
}

@Test func emptyInputHasZeroDuration() {
    let e = DurationEstimator()
    #expect(e.estimate(characterCount: 0) == 0)
    #expect(e.duration(ofBytes: 0, format: .kokoroPCM) == 0)
}

@Test func estimateMatchesMeasuredBaseline() {
    // Spec baseline: 180 chars produced 11.6s of audio.
    let e = DurationEstimator()
    let estimated = e.estimate(characterCount: 180)
    #expect(abs(estimated - 11.6) < 0.5)
}

@Test func honorsANonDefaultCharsPerSecond() {
    // charsPerSecond is an engine property, not a constant: a different engine or voice
    // measures differently, and every duration in the pipeline scales with it.
    let slow = DurationEstimator(charsPerSecond: 10.0)
    #expect(slow.charsPerSecond == 10.0)
    #expect(abs(slow.estimate(characterCount: 100) - 10.0) < 0.001)

    let fast = DurationEstimator(charsPerSecond: 30.8)
    #expect(abs(fast.estimate(characterCount: 154) - 5.0) < 0.001)

    // Half the rate is exactly twice the estimate for the same text.
    let half = DurationEstimator(charsPerSecond: DurationEstimator.defaultCharsPerSecond / 2)
    #expect(abs(half.estimate(characterCount: 154) - 20.0) < 0.001)

    // duration(ofBytes:) is a property of the audio format alone and must NOT move
    // when charsPerSecond does.
    #expect(slow.duration(ofBytes: 48000, format: .kokoroPCM)
            == DurationEstimator().duration(ofBytes: 48000, format: .kokoroPCM))

    #expect(DurationEstimator().charsPerSecond == DurationEstimator.defaultCharsPerSecond)
}

@Test func acceptsEverySupportedPositiveRate() {
    // The accepting side of `precondition(charsPerSecond > 0)`. Arbitrarily small positive
    // values are legal; only zero and negatives trap.
    //
    // The trapping side cannot be asserted on this toolchain: Swift 6.0.2 ships a
    // swift-testing without exit tests (`#expect(processExitsWith:)` does not exist), and a
    // precondition failure takes the whole test process down. It is a programmer-error
    // trap, not a recoverable error, so it is documented here rather than faked with a
    // throwing initializer.
    for rate in [0.001, 0.5, 1.0, 15.4, 1_000_000.0] {
        #expect(DurationEstimator(charsPerSecond: rate).charsPerSecond == rate)
    }
}
