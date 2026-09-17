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
