import Foundation
import MoxSpeakCore

// Usage:
//   moxspeak speak "some text"          reads the argument
//   moxspeak speak -                    reads stdin
//   Options: --voice <id> --speed <x> --port <n> --voices

func failUsage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: moxspeak speak <text|-> [--voice af_bella] [--speed 1.0] [--port 8880]
           moxspeak voices [--port 8880]

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { failUsage() }
args.removeFirst()

@MainActor
func option(_ name: String, default fallback: String) -> String {
    guard let index = args.firstIndex(of: "--\(name)"), index + 1 < args.count else {
        return fallback
    }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

let voice = option("voice", default: "af_bella")
let speed = Double(option("speed", default: "1.0")) ?? 1.0
let port = Int(option("port", default: "8880")) ?? 8880

let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: port))

switch command {
case "voices":
    let voices = try await provider.listVoices()
    for v in voices { print(v.id) }

case "speak":
    guard let source = args.first else { failUsage() }
    let text: String
    if source == "-" {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        text = String(data: input, encoding: .utf8) ?? ""
    } else {
        text = source
    }

    guard await provider.identityProbe() else {
        FileHandle.standardError.write(Data(
            "error: no compatible TTS engine at 127.0.0.1:\(port)\n".utf8))
        exit(1)
    }

    let session = SpeechSession(provider: provider)
    let engine = try PlaybackEngine(format: provider.outputFormat)
    // --speed is a playback setting, not a synthesis setting. TimePitch applies it
    // instantly and pitch-corrected, and synthesis stays at 1.0 where the duration
    // estimate that validation depends on is actually valid.
    engine.rate = Float(speed)
    try engine.start()

    await session.speak(text, voice: voice)
    let chunks = await session.chunks
    guard !chunks.isEmpty else { exit(0) }

    // Play in order, waiting for each chunk to be ready. Synthesis of later chunks
    // continues in the background while earlier ones play.
    let started = Date()
    var firstSoundReported = false
    for chunk in chunks {
        var state = await session.state(of: chunk.id)
        while case .pending = state {
            try await Task.sleep(for: .milliseconds(20))
            state = await session.state(of: chunk.id)
        }
        while case .synthesizing = state {
            try await Task.sleep(for: .milliseconds(20))
            state = await session.state(of: chunk.id)
        }
        switch state {
        case .rendered(let data, _):
            if !firstSoundReported {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                FileHandle.standardError.write(Data("time to first sound: \(ms)ms\n".utf8))
                firstSoundReported = true
            }
            do {
                try engine.enqueue(data)
            } catch {
                FileHandle.standardError.write(Data(
                    "chunk \(chunk.id) failed: \(error)\n".utf8))
            }
        case .failed(let reason):
            FileHandle.standardError.write(Data("chunk \(chunk.id) failed: \(reason)\n".utf8))
        default:
            break
        }
    }

    await engine.waitForDrain()
    engine.stop()

default:
    failUsage()
}
