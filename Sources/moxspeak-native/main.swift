import Foundation
import MoxSpeakCore
import MoxSpeakNative

// Development harness for the native engine. Not shipped; it exists so the acoustic and
// latency claims about MoxSpeakNative can be re-measured on demand rather than trusted.
//
//   moxspeak-native info
//   moxspeak-native say   <text> [--voice af_bella] [--speed 1.0] [--precision float32] [--out file.wav]
//   moxspeak-native batch <corpus.txt> <outdir>  [--voice ...] [--precision ...]
//   moxspeak-native bench <corpus.txt>           [--voice ...] [--precision ...]
//   moxspeak-native g2p   <corpus.txt>

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { if case .usage(let m) = self { m } else { "" } }
}

struct Options {
    var voice = "af_bella"
    var speed = 1.0
    var precision = NativeModelAssets.Precision.float32
    var out: String?
}

func parse(_ arguments: [String]) throws -> (positional: [String], options: Options) {
    var positional: [String] = []
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw CLIError.usage("\(argument) needs a value") }
            return arguments[index]
        }
        switch argument {
        case "--voice": options.voice = try value()
        case "--speed":
            let raw = try value()
            guard let parsed = Double(raw) else { throw CLIError.usage("bad --speed \(raw)") }
            options.speed = parsed
        case "--precision":
            let raw = try value()
            guard let parsed = NativeModelAssets.Precision(rawValue: raw) else {
                throw CLIError.usage("bad --precision \(raw); use float32 or float16")
            }
            options.precision = parsed
        case "--out": options.out = try value()
        default: positional.append(argument)
        }
        index += 1
    }
    return (positional, options)
}

func writeWAV(_ samples: [Float], to url: URL, sampleRate: Int = 24000) throws {
    let pcm = NativeWAV.pcm(samples)
    var header = Data()
    func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    header.append(Data("RIFF".utf8)); header.append(le32(UInt32(36 + pcm.count)))
    header.append(Data("WAVE".utf8))
    header.append(Data("fmt ".utf8)); header.append(le32(16)); header.append(le16(1)); header.append(le16(1))
    header.append(le32(UInt32(sampleRate))); header.append(le32(UInt32(sampleRate * 2)))
    header.append(le16(2)); header.append(le16(16))
    header.append(Data("data".utf8)); header.append(le32(UInt32(pcm.count)))
    try (header + pcm).write(to: url)
}

enum NativeWAV {
    /// Reuses the engine's own PCM conversion so the WAV under test and the bytes the app
    /// would play are produced by the same code.
    static func pcm(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        return data
    }
}

func lines(of path: String) throws -> [String] {
    try String(contentsOfFile: path, encoding: .utf8)
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

// MARK: - main

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else {
    log("usage: moxspeak-native <info|say|batch|bench|g2p> ...")
    exit(2)
}

do {
    let (positional, options) = try parse(Array(raw.dropFirst()))
    let assets = NativeModelAssets.resolveDefault(precision: options.precision)

    switch command {
    case "info":
        print("model dir : \(assets.directory.path)")
        print("weights   : \(assets.weightsURL.lastPathComponent) (\(options.precision.rawValue))")
        let exists = FileManager.default.fileExists(atPath: assets.weightsURL.path)
        print("present   : \(exists)")
        print("format    : \(NativeKokoroEngine.outputFormat.sampleRate) Hz, "
            + "\(NativeKokoroEngine.outputFormat.channels) ch, "
            + "\(NativeKokoroEngine.outputFormat.bitDepth)-bit, raw=\(NativeKokoroEngine.outputFormat.isRawPCM)")
        print("voices    : \(assets.availableVoices().count) — \(assets.availableVoices().prefix(8).joined(separator: ", "))")

    case "say":
        guard let text = positional.first else { throw CLIError.usage("say needs text") }
        let engine = try NativeKokoroEngine(assets: assets)
        let start = Date()
        let samples = try engine.synthesizeSamples(text: text, voice: options.voice, speed: options.speed)
        let elapsed = Date().timeIntervalSince(start)
        log(String(format: "gen=%.3fs audio=%.2fs samples=%d", elapsed, Double(samples.count) / 24000, samples.count))
        if let out = options.out {
            try writeWAV(samples, to: URL(fileURLWithPath: out))
            log("wrote \(out)")
        }

    case "batch":
        guard positional.count >= 2 else { throw CLIError.usage("batch <corpus> <outdir>") }
        let corpus = try lines(of: positional[0])
        let outDir = URL(fileURLWithPath: positional[1], isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let loadStart = Date()
        let engine = try NativeKokoroEngine(assets: assets)
        log(String(format: "load=%.3fs", Date().timeIntervalSince(loadStart)))

        var report: [[String: Any]] = []
        for (offset, text) in corpus.enumerated() {
            let index = offset + 1
            let start = Date()
            let samples = try engine.synthesizeSamples(text: text, voice: options.voice, speed: options.speed)
            let elapsed = Date().timeIntervalSince(start)
            let name = String(format: "native_%02d.wav", index)
            try writeWAV(samples, to: outDir.appendingPathComponent(name))
            report.append([
                "i": index, "text": text, "gen_sec": elapsed, "samples": samples.count,
                "audio_sec": Double(samples.count) / 24000, "file": name,
            ])
            log(String(format: "%02d gen=%.3fs audio=%.2fs :: %@", index, elapsed,
                       Double(samples.count) / 24000, text))
        }
        let json = try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        try json.write(to: outDir.appendingPathComponent("native_report.json"))

    case "bench":
        guard let path = positional.first else { throw CLIError.usage("bench <corpus>") }
        let corpus = try lines(of: path)
        let engine = try NativeKokoroEngine(assets: assets)

        var timings: [Double] = []
        for (offset, text) in corpus.enumerated() {
            let start = Date()
            let samples = try engine.synthesizeSamples(text: text, voice: options.voice, speed: options.speed)
            let elapsed = Date().timeIntervalSince(start)
            let tag = offset == 0 ? "warmup" : "run"
            log(String(format: "%@ %02d ttfa=%.3fs audio=%.2fs chars=%d", tag, offset + 1, elapsed,
                       Double(samples.count) / 24000, text.count))
            if offset > 0 { timings.append(elapsed) }
        }
        print(String(format: "precision=%@ n=%d median=%.3fs min=%.3fs max=%.3fs",
                     options.precision.rawValue, timings.count, median(timings),
                     timings.min() ?? .nan, timings.max() ?? .nan))

    case "g2p":
        guard let path = positional.first else { throw CLIError.usage("g2p <corpus>") }
        let corpus = try lines(of: path)
        let engine = try NativeKokoroEngine(assets: assets)
        var out: [[String: String]] = []
        for text in corpus {
            let phonemes = try engine.phonemes(for: text)
            out.append(["text": text, "phonemes": phonemes])
            log("\(text)\n  -> \(phonemes)")
        }
        let json = try JSONSerialization.data(
            withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(json)

    default:
        throw CLIError.usage("unknown command \(command)")
    }
} catch {
    log("error: \(error)")
    exit(1)
}
