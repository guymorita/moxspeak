import Testing
import Foundation
@testable import SpeakeasyCore

@Test func kokoroFormatHasExpectedByteRate() {
    let f = AudioFormat.kokoroPCM
    #expect(f.sampleRate == 24000)
    #expect(f.channels == 1)
    #expect(f.bitDepth == 16)
    #expect(f.bytesPerSecond == 48000)
}

@Test func chunkStateRenderedCarriesDuration() {
    let state = ChunkState.rendered(data: Data([0, 0]), duration: 1.5)
    guard case .rendered(_, let duration) = state else {
        Issue.record("expected rendered state")
        return
    }
    #expect(duration == 1.5)
}
