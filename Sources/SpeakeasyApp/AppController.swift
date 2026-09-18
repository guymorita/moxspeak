import AppKit
import SpeakeasyCore

/// The glue: clipboard in, `SpeechSession` in the middle, `PlaybackEngine` out, and every
/// state change reflected in the menu bar.
///
/// Everything here runs on the main actor. That is not laziness — `PlaybackEngine` is
/// main-actor-isolated for real thread-safety reasons, AppKit demands it, and the work
/// this class actually does (a few dictionary lookups and menu updates) is nothing next
/// to synthesis, which happens inside `SpeechSession`'s own actor and never blocks here.
@MainActor
final class AppController {

    private let port: Int
    private let provider: OpenAICompatibleProvider
    private let session: SpeechSession
    private let hotkeys = HotkeyManager()
    private let nowPlaying = NowPlayingController()
    private var menuBar: MenuBarController?

    /// A fresh `PlaybackEngine` per utterance rather than one reused for the app's
    /// lifetime. `AVAudioPlayerNode.stop()` and the pending-buffer count that
    /// `waitForDrain()` reads are easy to get out of step when a queue is torn down
    /// mid-playback, and a replaced utterance tears one down mid-playback every time.
    /// Building a new engine is a few milliseconds and makes "replace what's playing"
    /// exactly as simple as it sounds.
    private var engine: PlaybackEngine?
    private var playback: Task<Void, Never>?

    private var health = EngineHealth()
    private var voice = "af_bella"
    private var rate: Float = 1.0

    private var isPlaying = false
    /// Set when something went wrong with the current utterance, cleared when a new one
    /// starts. Sticky on purpose: an error that vanished after two seconds would be an
    /// error the user never saw.
    private var lastError: String?
    private var idleNote = "Ready"
    private var hotkeyWarning: String?

    init(port: Int) {
        self.port = port
        self.provider = OpenAICompatibleProvider(config: .kokoroLocal(port: port))
        self.session = SpeechSession(provider: provider)
    }

    // MARK: - Launch

    func start() {
        let menuBar = MenuBarController(actions: .init(
            speakClipboard: { [weak self] in self?.speakClipboard() },
            togglePause: { [weak self] in self?.togglePause() },
            stop: { [weak self] in self?.stop() },
            selectVoice: { [weak self] in self?.selectVoice($0) },
            selectRate: { [weak self] in self?.selectRate($0) },
            quit: { NSApplication.shared.terminate(nil) }
        ))
        self.menuBar = menuBar
        menuBar.setVoices([], selected: voice, note: "Loading voices…")
        menuBar.setSelectedRate(rate)

        installHotkeys()

        nowPlaying.onTogglePlayPause = { [weak self] in self?.togglePause() }
        nowPlaying.onStop = { [weak self] in self?.stop() }
        nowPlaying.activate()

        refresh()
        Task { await loadVoices() }
        AppLog.write("app: started, talking to 127.0.0.1:\(port)")
    }

    private func installHotkeys() {
        var problems: [String] = []
        do {
            try hotkeys.register(.optionShiftS) { [weak self] in self?.speakClipboard() }
        } catch {
            problems.append("\(error)")
        }
        do {
            try hotkeys.register(.optionShiftSpace) { [weak self] in self?.togglePause() }
        } catch {
            problems.append("\(error)")
        }

        guard !problems.isEmpty else { return }

        // A hotkey that quietly does nothing is the worst possible outcome here: the user
        // presses it, nothing happens, and there is no way to tell a taken shortcut from
        // a broken app. So it goes in the menu permanently *and* announces itself once.
        hotkeyWarning = problems.joined(separator: "; ")
        menuBar?.flash("Hotkey unavailable — see menu", seconds: 4)
        AppLog.write("hotkey: \(hotkeyWarning ?? "")")
    }

    private func loadVoices() async {
        do {
            let voices = try await provider.listVoices()
            health.markReachable()
            if !voices.contains(where: { $0.id == voice }), let first = voices.first {
                voice = first.id
            }
            menuBar?.setVoices(voices, selected: voice, note: nil)
            AppLog.write("voices: loaded \(voices.count)")
        } catch {
            // Reachable-but-unreadable and not-there-at-all are different problems with
            // different fixes, and reporting the first as the second would send the user
            // to restart an engine that is running fine.
            if error is DecodingError {
                health.markReachable()
                menuBar?.setVoices([], selected: voice,
                                   note: "Voice list unreadable — using \(voice)")
            } else {
                health.markUnreachable("nothing answering on 127.0.0.1:\(port)")
                menuBar?.setVoices([], selected: voice,
                                   note: "Voice list unavailable — engine unreachable")
            }
            AppLog.write("voices: failed — \(error)")
        }
        refresh()
    }

    // MARK: - Commands

    func speakClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Non-modal, self-clearing, and it says which of the two things happened
            // (nothing copied vs. something copied that is not text).
            menuBar?.flash("Clipboard is empty")
            idleNote = "Nothing to speak — the clipboard has no text"
            lastError = nil
            refresh()
            AppLog.write("speak: nothing to say — the clipboard holds no text")
            return
        }
        speak(text)
    }

    private func speak(_ text: String) {
        teardownPlayback()
        lastError = nil
        idleNote = "Ready"

        let engine: PlaybackEngine
        do {
            engine = try PlaybackEngine(format: provider.outputFormat)
            engine.rate = rate
            try engine.start()
        } catch {
            // The audio device refused. Nothing will ever be heard, so this must be as
            // loud as a synthesis failure.
            report("Audio output unavailable — \(Self.describe(error))")
            return
        }

        self.engine = engine
        isPlaying = true
        nowPlaying.beginPlaying(title: NowPlayingController.title(for: text), rate: rate)
        refresh()
        AppLog.write("speak: \(text.count) characters in \(voice) at \(rate)×")

        playback = Task { [weak self] in
            await self?.pump(text: text, engine: engine)
        }
    }

    func togglePause() {
        guard isPlaying, let engine else {
            menuBar?.flash("Nothing is playing")
            AppLog.write("pause: nothing is playing")
            return
        }
        if engine.isPaused {
            engine.resume()
        } else {
            engine.pause()
        }
        nowPlaying.setPaused(engine.isPaused)
        refresh()
        AppLog.write(engine.isPaused ? "pause: paused" : "pause: resumed")
    }

    func stop() {
        guard isPlaying else { return }
        teardownPlayback()
        idleNote = "Stopped"
        nowPlaying.clear()
        refresh()
    }

    private func selectVoice(_ id: String) {
        voice = id
        menuBar?.setSelectedVoice(id)
        // Synthesis of the current utterance is already in flight; swapping voices
        // mid-sentence would splice two speakers together, so this takes effect next time
        // and says so rather than appearing to have done nothing.
        if isPlaying {
            menuBar?.flash("Voice changes on next read")
        }
        refresh()
    }

    private func selectRate(_ value: Float) {
        rate = value
        // TimePitch applies this instantly and pitch-corrected, so the current utterance
        // changes speed under the user's ear with no re-synthesis. That immediacy is the
        // whole reason speed lives on playback rather than on the request.
        engine?.rate = value
        menuBar?.setSelectedRate(value)
        refresh()
    }

    // MARK: - Playback

    /// Walks the chunks in order, waiting for each to render and handing it to the audio
    /// engine. Synthesis of later chunks continues in the background inside
    /// `SpeechSession` while earlier ones play, so this loop spends nearly all its time
    /// suspended.
    private func pump(text: String, engine: PlaybackEngine) async {
        let started = Date()
        _ = await session.speak(text, voice: voice)
        let chunks = await session.chunks

        guard !chunks.isEmpty else {
            finish(failures: [], chunkCount: 0, heardAnything: false)
            return
        }

        var heardAnything = false
        var failures: [String] = []

        for chunk in chunks {
            if Task.isCancelled { return }

            var state = await session.state(of: chunk.id)
            waiting: while true {
                switch state {
                case .pending, .synthesizing:
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(20))
                    state = await session.state(of: chunk.id)
                case .rendered, .failed:
                    break waiting
                }
            }
            if Task.isCancelled { return }

            switch state {
            case .rendered(let data, _):
                if !heardAnything {
                    // Time to first sound is the single number that exposes the engine's
                    // documented slow rot, so it is measured from the moment the user
                    // asked, not from when synthesis happened to begin.
                    health.record(timeToFirstSound: Date().timeIntervalSince(started))
                    heardAnything = true
                    refresh()
                }
                do {
                    try engine.enqueue(data)
                } catch {
                    failures.append("chunk \(chunk.id + 1): \(Self.describe(error))")
                }
            case .failed(let reason):
                failures.append("chunk \(chunk.id + 1): \(Self.humanize(reason))")
            case .pending, .synthesizing:
                break  // unreachable: the loop above only exits on a terminal state
            }
        }

        await engine.waitForDrain()
        if Task.isCancelled { return }
        finish(failures: failures, chunkCount: chunks.count, heardAnything: heardAnything)
    }

    private func finish(failures: [String], chunkCount: Int, heardAnything: Bool) {
        AppLog.write("speak: finished \(chunkCount) chunk\(chunkCount == 1 ? "" : "s"), "
                     + "\(failures.count) failed, heard something: \(heardAnything)")
        isPlaying = false
        engine?.stop()
        engine = nil
        playback = nil
        nowPlaying.clear()

        if !heardAnything && chunkCount > 0 {
            // Nothing at all came back. Distinguishing "the engine is gone" from "the
            // engine is there and answering badly" needs one cheap question, and the
            // answer changes what the user should do about it.
            Task { [weak self] in
                guard let self else { return }
                let reachable = await self.provider.identityProbe()
                if !reachable {
                    self.health.markUnreachable("nothing answering on 127.0.0.1:\(self.port)")
                } else {
                    self.health.markReachable()
                }
                self.refresh()
            }
        }

        if failures.isEmpty {
            if chunkCount == 0 {
                idleNote = "Nothing to speak — that text had no readable words"
            } else {
                idleNote = "Finished \(chunkCount) chunk\(chunkCount == 1 ? "" : "s")"
            }
            refresh()
            return
        }

        let headline = Self.failureHeadline(failed: failures.count, of: chunkCount)
        report("\(headline) — \(failures[0])")
        AppLog.write("playback: \(headline); \(failures.joined(separator: " | "))")
    }

    private func teardownPlayback() {
        playback?.cancel()
        playback = nil
        engine?.stop()
        engine = nil
        isPlaying = false
        // Fire-and-forget by design: `SpeechSession.speak` bumps the generation
        // synchronously, so stale work is discarded whether or not this has landed yet,
        // and awaiting it here would put an unwinding network call on the hotkey path.
        Task { [session] in await session.cancelAll() }
    }

    private func report(_ message: String) {
        lastError = message
        isPlaying = false
        refresh()
        AppLog.write("error: \(message)")
    }

    // MARK: - Rendering state into the menu bar

    private func refresh() {
        guard let menuBar else { return }

        let icon: MenuBarController.IconState
        let line: String

        if let lastError {
            icon = .error
            line = lastError
        } else if isPlaying, let engine, engine.isPaused {
            icon = .paused
            line = "Paused"
        } else if isPlaying {
            icon = .speaking
            line = "Speaking at \(MenuBarController.rateTitle(rate)) in \(voice)"
        } else {
            icon = .idle
            line = idleNote
        }

        menuBar.setIcon(icon)
        menuBar.setStatusLine(line)
        menuBar.setEngineStatus(health.summary)
        menuBar.setWarning(hotkeyWarning)
        menuBar.setTransport(canSpeak: true,
                             isPlaying: isPlaying,
                             isPaused: engine?.isPaused ?? false)
    }

    // MARK: - Turning failures into sentences
    //
    // This is the visible half of the project's central principle. The backend returns
    // HTTP 200 with no audio, so a chunk can fail while everything upstream looks fine —
    // and the only place that failure can surface is here. Which means it has to surface
    // in words, not in debugger output: "engine returned no audio" tells a user what
    // happened, `emptyAudio` tells them the developer didn't finish the sentence.

    /// How many failed, out of how many, in English.
    nonisolated static func failureHeadline(failed: Int, of total: Int) -> String {
        if total <= 1 { return "Speech failed" }
        if failed >= total { return "All \(total) chunks failed" }
        return "\(failed) of \(total) chunks failed"
    }

    /// Rewrites `SpeechSession`'s failure reason into something a person can read.
    ///
    /// `ChunkState.failed` carries its reason as a `String` that the session built with
    /// `"\(error)"`, so what arrives here is Swift's synthesized enum description —
    /// `transport("Could not connect to the server.")`. Widening that public API to carry
    /// a typed error is a change to a component this app is supposed to be wiring up, not
    /// rewriting, so the translation happens at the UI boundary instead. Anything
    /// unrecognized is passed through verbatim rather than swallowed: a reason nobody
    /// anticipated is still more useful on screen than a shrug.
    nonisolated static func humanize(_ reason: String) -> String {
        if let inner = associatedValue(of: "transport", in: reason) { return inner }
        if let inner = associatedValue(of: "badResponse", in: reason) { return inner }
        if reason.hasPrefix("emptyAudio") { return "engine returned no audio" }
        if reason.hasPrefix("shortAudio") { return "engine returned truncated audio" }
        if reason.hasPrefix("formatMismatch") { return "engine returned an unexpected audio format" }
        if reason.hasPrefix("httpStatus") {
            guard let code = firstInteger(in: reason) else { return "engine returned an error" }
            return "engine returned HTTP \(code)"
        }
        return reason
    }

    /// Pulls `X` out of `case(X)` / `case("X")`, or nil when `reason` isn't that case.
    private nonisolated static func associatedValue(of label: String, in reason: String) -> String? {
        let opening = label + "("
        guard reason.hasPrefix(opening), reason.hasSuffix(")") else { return nil }
        var inner = String(reason.dropFirst(opening.count).dropLast())
        if inner.hasPrefix("\"") && inner.hasSuffix("\"") && inner.count >= 2 {
            inner = String(inner.dropFirst().dropLast())
        }
        return inner.isEmpty ? nil : inner
    }

    private nonisolated static func firstInteger(in text: String) -> Int? {
        let digits = text.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
        return Int(digits)
    }

    /// Errors reach the user as sentences, not as `Optional(SpeechError.badResponse(...))`.
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let speech as SpeechError:
            switch speech {
            case .httpStatus(let code, _): return "engine returned HTTP \(code)"
            case .emptyAudio: return "engine returned no audio"
            case .shortAudio(let expected, let got):
                return String(format: "engine returned %.1fs of audio where %.1fs was expected",
                              got, expected)
            case .formatMismatch: return "engine returned audio in an unexpected format"
            case .transport(let detail): return detail
            case .badResponse(let detail): return detail
            }
        default:
            return error.localizedDescription
        }
    }
}
