import Foundation
import MoxSpeakCore
import MoxSpeakNative

/// Which engine turns text into audio.
///
/// Two, and deliberately not one. The native engine is the default because everything it
/// needs ships inside the `.app` — no Python, no server, no port — and that is the whole
/// point of this plan. The HTTP engine stays because it is the only way to point MoxSpeak
/// at a machine that is not this one, and because it is the escape hatch if the native
/// path ever regresses: an engine you cannot switch away from is an engine you have to be
/// right about forever.
///
/// The raw values are what gets written to `UserDefaults`, so they are part of the
/// on-disk format and must not be renamed casually. `Settings.resolveEngine` treats
/// anything it does not recognise as "no preference" rather than as an error.
enum EngineChoice: String, CaseIterable, Sendable {

    /// Kokoro, in this process. Weights, voices, lexicon and Metal library all inside the
    /// bundle.
    case native

    /// An OpenAI-compatible HTTP server — Kokoro-FastAPI on localhost by default.
    case http

    /// What a machine with nothing else installed gets.
    static let `default`: EngineChoice = .native

    // MARK: - Words

    /// Short enough for the parent menu item: "Engine: Built in".
    var shortName: String {
        switch self {
        case .native: "Built in"
        case .http: "Kokoro server"
        }
    }

    /// The submenu row. Says what the choice actually means, not which class implements it.
    func menuTitle(port: Int) -> String {
        switch self {
        case .native: "Built in, no server needed"
        case .http: "Kokoro server on 127.0.0.1:\(port)"
        }
    }

    func menuDetail(port: Int) -> String {
        switch self {
        case .native:
            "Speech is generated inside MoxSpeak. Works offline, with nothing else running."
        case .http:
            "Send text to an OpenAI-compatible speech server on port \(port). "
            + "Something has to be listening there."
        }
    }

    /// How this engine is named in `~/Library/Logs/MoxSpeak.log`. Stable and greppable;
    /// the menu wording is free to change without breaking anyone's log-reading habit.
    var logName: String { rawValue }

    /// What the menu says when the engine could not be reached at all.
    func unreachableReason(port: Int) -> String {
        switch self {
        case .native: "the built-in engine could not read its voices"
        case .http: "nothing answering on 127.0.0.1:\(port)"
        }
    }

    /// Shown instead of the voice list when there is no list.
    var voiceListUnavailableNote: String {
        switch self {
        case .native: "Voice list unavailable. The built-in engine has no voices."
        case .http: "Voice list unavailable. Engine unreachable."
        }
    }

    // MARK: - What counts as slow here

    /// A median time-to-first-sound above this is reported as slow.
    ///
    /// Per-engine because the two are an order of magnitude apart and a single number
    /// would be wrong for one of them. The HTTP server's healthy figure is ~1.95 s
    /// (Phase 2), so 2.5 s catches its documented slow rot. The native engine measured
    /// 0.359 s unconstrained and 0.734 s at the pessimistic floor of the Phase 3b
    /// envelope suite (256 MB ceiling, no buffer cache), so 1.25 s sits above anything
    /// ever measured as healthy and below the *server's* healthy figure: "slow" on
    /// native means genuinely degraded, not merely busy.
    var slowThreshold: TimeInterval {
        switch self {
        case .native: 1.25
        case .http: 2.5
        }
    }

    /// The one action a user could take. Different per engine, because there is no server
    /// to restart when the engine is this process.
    var slowHint: String {
        switch self {
        case .native: "quitting and reopening MoxSpeak may help"
        case .http: "restarting it may help"
        }
    }

    // MARK: - Construction

    func makeProvider(port: Int) -> any SpeechProvider {
        switch self {
        case .native:
            // fp16 — what `build-app.sh` stages into the bundle, and what Phase 3
            // measured as acoustically indistinguishable from f32 at half the size.
            NativeSpeechProvider()
        case .http:
            OpenAICompatibleProvider(config: .kokoroLocal(port: port))
        }
    }
}

/// One engine, and the session built around it.
///
/// These two are replaced together or not at all. `SpeechSession` reads
/// `recommendedCharacterCap` once, at construction, to size its `Segmenter` — so a
/// session that outlived an engine change would keep chunking for the engine it no longer
/// talks to (150-character chunks into the native engine, or 100 into the server). Making
/// the pair a single value means "switch engines" is one assignment and cannot be done
/// half way.
///
/// `characterCap` and `normalizesText` on the session are what make that checkable rather
/// than assumed — `AppController` writes both to the log on every switch.
struct EngineRuntime {

    let choice: EngineChoice
    let provider: any SpeechProvider
    let session: SpeechSession

    init(choice: EngineChoice, port: Int) {
        let provider = choice.makeProvider(port: port)
        self.choice = choice
        self.provider = provider
        self.session = SpeechSession(provider: provider)
    }

    /// Pays the model-load cost up front so the first hotkey press does not.
    ///
    /// Returns nil for an engine with nothing to warm — the HTTP server is somebody
    /// else's process and was warm or cold before we got here. For the native engine a
    /// cold first utterance is ~0.9-1.0 s against ~0.35 s steady state, nearly all of it
    /// Metal pipeline compilation and lazy lexicon loading, so this is the difference
    /// between meeting the half-second target on the first press and meeting it on the
    /// second.
    func warmUp(voice: String) async throws -> TimeInterval? {
        guard let native = provider as? NativeSpeechProvider else { return nil }
        return try await native.prepare(voice: voice)
    }

    /// One cheap question: is this engine there at all?
    ///
    /// The HTTP provider has `identityProbe` for exactly this — a port is not an
    /// identity. The native engine has no socket to knock on, so the equivalent question
    /// is whether it can still see its voices; if it cannot, its assets are gone and it
    /// will not be synthesizing anything either.
    func probeReachable() async -> Bool {
        if let http = provider as? OpenAICompatibleProvider {
            return await http.identityProbe()
        }
        do {
            let voices = try await provider.listVoices()
            return !voices.isEmpty
        } catch {
            return false
        }
    }
}
