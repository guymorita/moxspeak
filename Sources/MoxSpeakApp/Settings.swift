import Foundation
import MoxSpeakCore

/// The three things the app remembers between launches: the chosen engine, the chosen
/// voice and the chosen speed.
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
    }

    /// Every key this app writes, in one place, because `Reset` has to be able to check
    /// that they are all gone — and a key added to `Key` without being added here would
    /// be a preference that silently survives a reset.
    static let allKeys = [Key.voice, Key.rate, Key.engine]

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

    /// Picks the speed to actually use, given what was stored and what the menu offers.
    ///
    /// Three steps, each guarding against a different kind of junk:
    ///
    /// 1. Absent, non-finite or non-positive is not a speed at all — that is a missing
    ///    key, a corrupted value, or something written by a future version. Default.
    /// 2. Clamp into `PlaybackEngine.rateRange`, the range the audio unit will actually
    ///    honour. Anything outside it would be silently clamped downstream anyway; doing
    ///    it here means the menu and the ear agree.
    /// 3. Snap to the nearest speed the app can offer. The app itself only ever writes
    ///    one of these five, so anything else came from somewhere else — and a rate with
    ///    no matching menu item is exactly the "looks configured, isn't" state this whole
    ///    function exists to prevent. Skipped when nothing is on offer.
    static func resolveRate(stored: Float?, offered: [Float]) -> Float {
        guard let stored, stored.isFinite, stored > 0 else { return defaultRate }

        let range = PlaybackEngine.rateRange
        let clamped = min(max(stored, range.lowerBound), range.upperBound)

        guard !offered.isEmpty else { return clamped }
        return offered.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? clamped
    }
}
