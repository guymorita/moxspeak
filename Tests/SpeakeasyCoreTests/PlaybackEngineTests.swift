import Testing
import Foundation
import AVFoundation
@testable import SpeakeasyCore

@Test func convertsRawPCMBytesToABuffer() throws {
    // One second of silence: 48000 bytes at 24kHz 16-bit mono.
    let data = Data(count: 48000)
    let buffer = try #require(PlaybackEngine.buffer(from: data, format: .kokoroPCM))
    #expect(buffer.frameLength == 24000)
    #expect(buffer.format.channelCount == 1)
    #expect(buffer.format.sampleRate == 24000)
}

@Test func preservesSampleValues() throws {
    // Two frames: 0x0100 == 256, 0xFF7F == 32767 little-endian.
    var data = Data()
    data.append(contentsOf: [0x00, 0x01])
    data.append(contentsOf: [0xFF, 0x7F])
    let buffer = try #require(PlaybackEngine.buffer(from: data, format: .kokoroPCM))
    #expect(buffer.frameLength == 2)
    let channel = try #require(buffer.floatChannelData?[0])
    #expect(abs(channel[0] - (256.0 / 32768.0)) < 0.0001)
    #expect(abs(channel[1] - (32767.0 / 32768.0)) < 0.0001)
}

@Test func rejectsOddLengthData() {
    // 16-bit samples cannot come in odd byte counts.
    #expect(PlaybackEngine.buffer(from: Data(count: 3), format: .kokoroPCM) == nil)
}

@Test func emptyDataProducesNoBuffer() {
    #expect(PlaybackEngine.buffer(from: Data(), format: .kokoroPCM) == nil)
}
