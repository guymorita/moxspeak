import Foundation
import MoxSpeakCore

/// What the app remembers between launches: the chosen engine, voice and speed, and the
/// three global keyboard shortcuts.
///
/// Deliberately two halves. The *resolving* half is pure — it takes what was read off
/// disk plus what is actually available right now, and returns something safe to use.
/// Every decision worth arguing about lives there, which is why it is `static`, takes
/// its whole world as parameters, and is what the tests exercise. The *storing* half is
/// a handful of `UserDefaults` calls and nothing else.
///
/// Why resolving exists at all: a preference read back from disk is not a preference,
/// it is a rumour. The voice saved last week may be gone from the engine today — Kokoro
/// serves whatever voice files happen to be on that machine, and the list changes when
/// the engine does. A speed read back is just a number, and a number can be zero, or
/// 47, or NaN. Restoring either verbatim gives you an app that *looks* configured and
/// does not work: synthesis requests a voice the engine 404s on, or playback runs at a
/// rate no menu item matches and no user chose. Falling back isn't politeness, it's the
/// difference between a stale preference and a broken launch.
struct Settings {

    /// Matches `AppController`'s own starting voice. Kokoro ships it; if it is somehow
    /// missing, `resolveVoice` falls through to whatever the engine does offer.
    static let defaultVoice = "af_bella"
    static let defaultRate: Float = 1.0

    /// What a machine that has never been configured gets: the engine that needs nothing
    /// else installed.
    static let defaultEngine = EngineChoice.default

    private enum Key {
        static let voice = "voice"
        static let rate = "rate"
        static let engine = "engine"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let telemetryEnabled = "telemetryEnabled"
        static let installID = "installID"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    /// Every key this app writes, in one place, because `Reset` has to be able to check
    /// that they are all gone — and a key added to `Key` without being added here would
    /// be a preference that silently survives a reset.
    static let allKeys = [Key.voice, Key.rate, Key.engine,
                          Key.hasCompletedFirstRun, Key.telemetryEnabled, Key.installID,
                          Key.lastUpdateCheck]
                       + HotkeyAction.allCases.map(\.settingsKey)

    /// `.standard` is the bundle identifier's own suite — `com.moxspeak.menubar` — which
    /// macOS manages. No suite name, no plist path, nothing this app has to create,
    /// migrate or clean up.
    private let defaults: UserDefaults

    /// The name of the domain `defaults` writes into — the bundle identifier for
    /// `.standard`, and nil for a binary run straight out of `.build`, which has no
    /// Info.plist to take one from.
    ///
    /// Carried here rather than looked up at the point of use so that `Reset` empties the
    /// same domain these values were written to. A `Settings` on a throwaway suite (every
    /// test) and a `Settings` on `.standard` must each be erasable, and only the thing
    /// holding the store knows which is which.
    let domain: String?

    init(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.domain = domain
    }

    /// The store behind these settings. Exposed for `Reset`, which has to empty the same
    /// `UserDefaults` this writes to rather than assume `.standard`.
    var store: UserDefaults { defaults }

    // MARK: - First run

    /// False exactly once per install: on the very first launch, before the welcome
    /// window has been dismissed.
    ///
    /// Written when the window is dismissed rather than when it is shown, so a first
    /// launch that crashes or is force-quit mid-welcome shows it again rather than
    /// leaving somebody with a menu bar app they never learned to use.
    ///
    /// `nonmutating` because nothing in `Settings` itself changes — the write lands in
    /// `UserDefaults`, which is a reference type. Without it, every holder of a `Settings`
    /// would have to keep it in a `var` just to record a fact about the user.
    var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstRun) }
        nonmutating set { defaults.set(newValue, forKey: Key.hasCompletedFirstRun) }
    }

    // MARK: - Telemetry

    /// Whether anonymous usage events and crash reports may be sent. On by default,
    /// stated on the welcome window, switchable under Advanced.
    ///
    /// `object(forKey:)` rather than `bool(forKey:)` because `bool` cannot tell "never
    /// set" from "set to false", and the two have opposite meanings here: an unset value
    /// is a fresh install that has consented by default, and false is somebody who went
    /// and turned it off. Reading it as `bool` would silently re-enable telemetry for
    /// every user who opted out, on the next launch.
    var isTelemetryEnabled: Bool {
        get { defaults.object(forKey: Key.telemetryEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.telemetryEnabled) }
    }

    /// A random identifier for this installation, made on first use.
    ///
    /// Random rather than derived from anything about the machine — no serial number, no
    /// hardware UUID, no MAC address, nothing that could identify the same person across
    /// a reinstall or correlate with another product. "Reset MoxSpeak…" clears it, and
    /// the next launch is a new install as far as any analytics is concerned, which is
    /// the behaviour somebody clicking reset is entitled to expect.
    func installID() -> String {
        if let existing = defaults.string(forKey: Key.installID), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Key.installID)
        return fresh
    }

    // MARK: - Updates

    /// When MoxSpeak last asked GitHub whether there was a newer release.
    ///
    /// Persisted rather than kept in memory because a menu bar app is launched rarely and
    /// runs for weeks. Checking only at launch would mean never asking for exactly the
    /// people most likely to be running an old build.
    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    // MARK: - Storing

    /// The voice exactly as it was written, or nil when nothing has ever been saved.
    /// Unvalidated on purpose: validating needs the engine's current voice list, which
    /// this type has no business fetching. Hand it to `resolveVoice` before using it.
    var storedVoice: String? {
        get { defaults.string(forKey: Key.voice) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Key.voice) }
            else { defaults.removeObject(forKey: Key.voice) }
        }
    }

    /// The speed exactly as it was written, or nil when nothing has ever been saved.
    ///
    /// `object(forKey:)` rather than `float(forKey:)` alone, because `float(forKey:)`
    /// answers `0` both for "saved as zero" and for "never saved" — and those must not
    /// resolve to the same thing. A first launch has to yield the default, not the
    /// clamped floor of a value nobody chose.
    var storedRate: Float? {
        get {
            guard defaults.object(forKey: Key.rate) != nil else { return nil }
            return defaults.float(forKey: Key.rate)
        }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Key.rate) }
            else { defaults.removeObject(forKey: Key.rate) }
        }
    }

    /// The engine exactly as it was written, or nil when nothing has ever been saved.
    ///
    /// A `String?` rather than an `EngineChoice?` for the same reason `storedVoice` is
    /// not validated here: what is on disk is a rumour. It may have been written by a
    /// future version that knows an engine this one does not, or hand-edited with
    /// `defaults write`. Decoding is `resolveEngine`'s job, and its answer is always a
    /// usable engine.
    var storedEngine: String? {
        get { defaults.string(forKey: Key.engine) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Key.engine) }
            else { defaults.removeObject(forKey: Key.engine) }
        }
    }

    /// One hotkey exactly as it was written, or nil when nothing has ever been saved.
    ///
    /// A `String?` for the same reason `storedEngine` is: what is on disk is a rumour.
    /// It may be from a format this version does not know, hand-edited, or — the case
    /// this whole feature exists for — a combination macOS stopped delivering in 2024.
    /// Decoding and judging it is `resolveHotkey`'s job.
    func storedHotkey(_ action: HotkeyAction) -> String? {
        defaults.string(forKey: action.settingsKey)
    }

    func setStoredHotkey(_ value: String?, for action: HotkeyAction) {
        if let value { defaults.set(value, forKey: action.settingsKey) }
        else { defaults.removeObject(forKey: action.settingsKey) }
    }

    // MARK: - Resolving (pure)

    /// Picks the voice to actually use, given what was stored and what the engine offers.
    ///
    /// `available` empty is not treated as "the stored voice is invalid". It means the
    /// question cannot be asked yet — at launch the list has not loaded, and when the
    /// engine is unreachable it never will. Throwing away the user's choice on the
    /// strength of a list we do not have would turn a temporarily unreachable engine
    /// into a permanently forgotten preference.
    static func resolveVoice(stored: String?, available: [String]) -> String {
        let wanted = stored?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (wanted?.isEmpty == false) ? wanted! : nil

        guard !available.isEmpty else { return candidate ?? defaultVoice }
        if let candidate, available.contains(candidate) { return candidate }
        if available.contains(defaultVoice) { return defaultVoice }
        return available[0]
    }

    /// Picks the engine to actually use, given what was stored and what this build has.
    ///
    /// Unlike a voice, an unrecognised engine is not a temporary absence that might come
    /// back — this build either has the code for it or it does not — so there is nothing
    /// to preserve by hesitating, and the answer is the default. The `available`
    /// parameter exists so a build that ever ships without one of them (or a test) is
    /// answered honestly rather than handed an engine that is not there.
    static func resolveEngine(stored: String?,
                              available: [EngineChoice] = EngineChoice.allCases) -> EngineChoice {
        guard !available.isEmpty else { return defaultEngine }

        let wanted = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let candidate = EngineChoice(rawValue: wanted), available.contains(candidate) {
            return candidate
        }
        if available.contains(defaultEngine) { return defaultEngine }
        return available[0]
    }

    /// Picks the speed to actually use, given what was stored.
    ///
    /// Two steps, each guarding against a different kind of junk:
    ///
    /// 1. Absent, non-finite or non-positive is not a speed at all — that is a missing
    ///    key, a corrupted value, or something written by a future version. Default.
    /// 2. Clamp into `PlaybackEngine.rateRange`, the range the audio unit will actually
    ///    honour. Anything outside it would be silently clamped downstream anyway; doing
    ///    it here means the menu and the ear agree.
    ///
    /// Unlike voice or engine, a stored speed is never snapped to one of a handful of
    /// values: the speed control offers the whole range, not five presets, so 1.32 is as
    /// legitimate a restored value as 1.25 is. (`SpeedControl.snapped` still exists — it
    /// governs a slider *drag*, which is a UI gesture with no business here.)
    static func resolveRate(stored: Float?) -> Float {
        guard let stored, stored.isFinite, stored > 0 else { return defaultRate }

        let range = PlaybackEngine.rateRange
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    /// What a stored hotkey resolves to, and what should be said and written because of
    /// it.
    struct HotkeyResolution: Equatable {
        /// The combination to actually register. Always usable — `resolveHotkey` never
        /// returns one macOS would refuse to deliver.
        var hotkey: Hotkey
        /// One line for the log, or nil when nothing happened worth mentioning. A binding
        /// must never change under a user without a trace, so every path that does not
        /// hand back exactly what was stored fills this in.
        var note: String?
        /// True when what is on disk no longer matches what the app is using, so the
        /// caller should write the resolved value back. A migration that is not persisted
        /// is a migration that has to be re-explained on every launch — and, worse, a
        /// preferences file that still holds a dead shortcut.
        var shouldRestore: Bool
    }

    /// Picks the shortcut to actually register, given what was stored.
    ///
    /// The same shape as `resolveVoice` and `resolveRate` — stored value in, safe value
    /// out — with one extra job those two do not have: a stored value here can be
    /// *well-formed and still dead*. ⌥⇧S parses perfectly and has been unable to fire
    /// since macOS 15 (see `Hotkey`). Handing it back would leave the user on a shortcut
    /// that cannot work, with a log that says everything is fine.
    ///
    /// Four cases, in order:
    ///
    /// 1. **Nothing stored.** The default. Silent — this is a first launch, not an event.
    /// 2. **Stored, but not readable.** A future version's format, or a hand-edit. The
    ///    default, and say so; the alternative is registering nonsense.
    /// 3. **Stored, readable, and macOS will not deliver it.** Move it: the three shipped
    ///    defaults become the three new defaults, anything else keeps its key and gains
    ///    Control (`Hotkey.workingEquivalent`). Say exactly what moved and why.
    /// 4. **Stored, readable, usable.** Exactly what was stored. Silent.
    static func resolveHotkey(stored: String?, action: HotkeyAction) -> HotkeyResolution {
        let fallback = action.defaultHotkey

        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return HotkeyResolution(hotkey: fallback, note: nil, shouldRestore: false)
        }

        guard let candidate = Hotkey(storageString: trimmed) else {
            return HotkeyResolution(
                hotkey: fallback,
                note: "the stored \(action.logName) could not be read (\"\(trimmed)\") — "
                    + "using \(fallback.label)",
                shouldRestore: true)
        }

        guard let reason = candidate.rejection else {
            return HotkeyResolution(hotkey: candidate, note: nil, shouldRestore: false)
        }

        let replacement = candidate.workingEquivalent(for: action) ?? fallback
        return HotkeyResolution(
            hotkey: replacement,
            note: "the stored \(action.logName) \(candidate.label) cannot work — "
                + "\(reason.logReason) — moved to \(replacement.label)",
            shouldRestore: true)
    }
}
