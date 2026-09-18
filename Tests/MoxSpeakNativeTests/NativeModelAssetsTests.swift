import Testing
import Foundation
@testable import MoxSpeakNative
import MoxSpeakCore

// These run with no weights on disk. Everything that needs a 312 MB file lives in
// NativeSynthesisTests and skips itself when the file is absent.

@Test func precisionSelectsTheWeightFile() {
    let directory = URL(fileURLWithPath: "/models")
    #expect(NativeModelAssets(directory: directory, precision: .float32)
        .weightsURL.lastPathComponent == "kokoro-v1_0.safetensors")
    #expect(NativeModelAssets(directory: directory, precision: .float16)
        .weightsURL.lastPathComponent == "kokoro-v1_0-fp16.safetensors")
}

@Test func voicesLiveInASubdirectory() {
    let assets = NativeModelAssets(directory: URL(fileURLWithPath: "/models"))
    #expect(assets.voicesDirectory.path == "/models/voices")
    #expect(assets.voiceURL(named: "af_bella").path == "/models/voices/af_bella.safetensors")
}

@Test func environmentOverrideWinsOverEverything() {
    let directory = NativeModelAssets.defaultDirectory(
        environment: ["MOXSPEAK_MODEL_DIR": "/somewhere/else"]
    )
    #expect(directory.path == "/somewhere/else")
}

@Test func environmentOverrideExpandsATilde() {
    let directory = NativeModelAssets.defaultDirectory(environment: ["MOXSPEAK_MODEL_DIR": "~/m"])
    #expect(!directory.path.hasPrefix("~"))
    #expect(directory.path.hasSuffix("/m"))
}

@Test func anEmptyOverrideIsIgnoredRatherThanObeyed() {
    // An unset-but-exported variable is a real thing that happens in launchd plists and
    // CI. Treating "" as a model directory would send resolution to the filesystem root.
    let directory = NativeModelAssets.defaultDirectory(environment: ["MOXSPEAK_MODEL_DIR": ""])
    #expect(directory.path != "")
    #expect(directory.path != "/")
}

@Test func validationNamesTheMissingDirectory() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let assets = NativeModelAssets(directory: missing)
    #expect(throws: NativeModelAssets.ResolutionError.directoryMissing(missing)) {
        try assets.validate()
    }
}

@Test func validationNamesTheMissingWeightFileWhenTheDirectoryExists() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let assets = NativeModelAssets(directory: directory)
    #expect(throws: NativeModelAssets.ResolutionError.weightsMissing(assets.weightsURL)) {
        try assets.validate()
    }
}

@Test func availableVoicesIsEmptyRatherThanThrowingWhenTheDirectoryIsGone() {
    let assets = NativeModelAssets(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    #expect(assets.availableVoices().isEmpty)
}

@Test func availableVoicesListsBasenamesSorted() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let voices = directory.appendingPathComponent("voices", isDirectory: true)
    try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for name in ["bm_george.safetensors", "af_bella.safetensors", "notes.txt"] {
        try Data().write(to: voices.appendingPathComponent(name))
    }

    #expect(NativeModelAssets(directory: directory).availableVoices() == ["af_bella", "bm_george"])
}

// MARK: - PCM

// The engine's output has to be byte-for-byte what the existing playback path already
// consumes from the HTTP provider. Nothing downstream inspects the format, so a wrong
// sample width or byte order would play as noise rather than fail.

@Test func nativeOutputFormatIsExactlyTheFormatPlaybackExpects() {
    #expect(NativeKokoroEngine.outputFormat == AudioFormat.kokoroPCM)
    #expect(NativeKokoroEngine.outputFormat.sampleRate == 24000)
    #expect(NativeKokoroEngine.outputFormat.channels == 1)
    #expect(NativeKokoroEngine.outputFormat.bitDepth == 16)
    #expect(NativeKokoroEngine.outputFormat.isRawPCM)
}

@Test func pcmIsTwoBytesPerSample() {
    #expect(NativeKokoroEngine.pcm16(from: [Float](repeating: 0, count: 100)).count == 200)
    #expect(NativeKokoroEngine.pcm16(from: []).isEmpty)
}

@Test func pcmIsLittleEndianSigned16() {
    let data = NativeKokoroEngine.pcm16(from: [0.0, 1.0, -1.0, 0.5])
    let values: [Int16] = stride(from: 0, to: data.count, by: 2).map {
        Int16(littleEndian: Int16(data[$0]) | (Int16(bitPattern: UInt16(data[$0 + 1]) << 8)))
    }
    #expect(values[0] == 0)
    #expect(values[1] == 32767)
    #expect(values[2] == -32767)
    #expect(values[3] == 16383)
}

@Test func pcmClampsRatherThanWrappingOnOverdrivenSamples() {
    // iSTFTNet output is not guaranteed to stay inside [-1, 1]. Wrapping instead of
    // clamping turns a loud sample into a full-scale sample of the opposite sign, which
    // is an audible click.
    let data = NativeKokoroEngine.pcm16(from: [4.0, -4.0])
    #expect(Array(data) == [0xFF, 0x7F, 0x01, 0x80])
}

@Test func pcmDurationMatchesWhatTheFormatWouldCompute() {
    // One second of 24 kHz mono 16-bit audio, measured the way the session measures it.
    let data = NativeKokoroEngine.pcm16(from: [Float](repeating: 0, count: 24000))
    #expect(Double(data.count) / Double(AudioFormat.kokoroPCM.bytesPerSecond) == 1.0)
}
