import Testing
import Foundation
@testable import MoxSpeakApp
@testable import MoxSpeakCore

// Phase 6 is a behaviour change, and its two risky halves are both testable without a
// running app: which engine a stored preference resolves to, and whether building a new
// `EngineRuntime` really carries the new engine's numbers into the session. The second is
// the one that would fail silently — a session reused across an engine change keeps the
// old engine's chunk size and normalization, and nothing about the audio says so.

// MARK: - The default

@Test func nothingStoredMeansTheEngineThatNeedsNothingElseInstalled() {
    // The point of the whole plan: a machine with no Python and no server speaks.
    #expect(Settings.resolveEngine(stored: nil) == .native)
    #expect(Settings.defaultEngine == .native)
    #expect(EngineChoice.default == .native)
}

@Test func bothEnginesStayAvailable() {
    // The HTTP engine is how someone points at a remote or beefier engine, and the escape
    // hatch if the native path regresses. Deleting it is a decision, not a cleanup.
    #expect(EngineChoice.allCases.count == 2)
    #expect(EngineChoice.allCases.contains(.http))
}

// MARK: - Storing and restoring

@Test func aStoredEngineComesBackUnchanged() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        #expect(settings.storedEngine == nil, "a first launch has no engine stored")

        settings.storedEngine = EngineChoice.http.rawValue
        #expect(Settings(defaults: defaults).storedEngine == "http")
        #expect(Settings.resolveEngine(stored: "http") == .http)

        settings.storedEngine = nil
        #expect(settings.storedEngine == nil)
    }
}

@Test func rubbishOnDiskResolvesToTheDefaultRatherThanFailing() {
    // `defaults write com.moxspeak.menubar engine kokoro-v3`, or a preference written by a
    // future version that knows an engine this build does not. Neither is recoverable by
    // waiting, so there is nothing to preserve by hesitating.
    for junk in ["", "   ", "kokoro-v3", "HTTP", "native ", "0", "true"] {
        #expect(Settings.resolveEngine(stored: junk) == .native,
                "\(junk.debugDescription) should resolve to the default")
    }
}

@Test func anEngineThisBuildDoesNotHaveIsNotHandedBack() {
    // `available` is not decoration: resolving to an engine that isn't there would be the
    // "looks configured, doesn't work" state `Settings` exists to prevent.
    #expect(Settings.resolveEngine(stored: "native", available: [.http]) == .http)
    #expect(Settings.resolveEngine(stored: nil, available: [.http]) == .http)
    #expect(Settings.resolveEngine(stored: "http", available: []) == .native,
            "with nothing on offer the answer is still an engine, not a crash")
}

// MARK: - What a switch actually changes

@Test func eachEngineBringsItsOwnChunkSizeIntoTheSession() {
    // `recommendedCharacterCap` was dead code until Phase 4 wired it to the segmenter. It
    // is read exactly once, inside `SpeechSession.init`, which is why an engine switch has
    // to build a new session — and why this asserts through the session rather than
    // through the provider that supplied the number.
    let native = EngineRuntime(choice: .native, port: 8880)
    let http = EngineRuntime(choice: .http, port: 8880)

    #expect(native.session.characterCap == 350)
    #expect(http.session.characterCap == 150)
    #expect(native.provider.recommendedCharacterCap == native.session.characterCap)
    #expect(http.provider.recommendedCharacterCap == http.session.characterCap)
}

@Test func eachEngineBringsItsOwnNormalizationIntoTheSession() {
    // Silently destructive in both directions: the server normalizes for itself and
    // doubling it reads "$5" as "five dollars dollars", while the native engine normalizes
    // nothing and reads "$1,234.56" as unrelated digits. Neither throws.
    let native = EngineRuntime(choice: .native, port: 8880)
    let http = EngineRuntime(choice: .http, port: 8880)

    #expect(native.session.normalizesText)
    #expect(!http.session.normalizesText)
}

@Test func switchingEngineAtRuntimeChangesBothNumbers() {
    // The failure this guards against is a session that outlives the engine it was built
    // for: 150-character chunks fed to the native engine, or the server handed text that
    // has already been normalized. Replacing the runtime is what prevents it, so replacing
    // the runtime is what is asserted.
    var runtime = EngineRuntime(choice: .native, port: 8880)
    let before = (cap: runtime.session.characterCap, normalizes: runtime.session.normalizesText)

    runtime = EngineRuntime(choice: .http, port: 8880)
    let after = (cap: runtime.session.characterCap, normalizes: runtime.session.normalizesText)

    #expect(before.cap != after.cap)
    #expect(before.normalizes != after.normalizes)
    #expect(after.cap == 150 && after.normalizes == false)
}

@Test func bothEnginesAgreeOnTheAudioFormatPlaybackIsBuiltFrom() {
    // `AppController` builds its `PlaybackEngine` from `provider.outputFormat` on every
    // utterance. They happen to match today; if they ever stop, the engine that does not
    // match must not be reached through a playback path built for the other.
    let native = EngineRuntime(choice: .native, port: 8880)
    let http = EngineRuntime(choice: .http, port: 8880)
    #expect(native.provider.outputFormat == http.provider.outputFormat)
}

// MARK: - The engine list reflects reality

@Test func theHTTPEngineNamesThePortSoAnUnreachableServerIsActionable() {
    // "Engine unreachable" without a port sends the user nowhere.
    #expect(EngineChoice.http.unreachableReason(port: 9999).contains("9999"))
    #expect(EngineChoice.http.menuTitle(port: 9999).contains("9999"))
}

@Test func theNativeEngineNeverClaimsThereIsASocketToFix() {
    // There is no server to check, no port to free, and nothing to restart. Advice that
    // does not match the thing it is about is worse than none.
    let reason = EngineChoice.native.unreachableReason(port: 8880)
    #expect(!reason.contains("8880"))
    #expect(!reason.lowercased().contains("server"))
    #expect(!EngineChoice.native.slowHint.lowercased().contains("server"))
}

@Test func whatCountsAsSlowIsPerEngineAndReachesTheMenu() {
    // The server's healthy figure is ~1.95s and the native engine's is ~0.36s. A single
    // threshold would either never fire for one or always fire for the other.
    #expect(EngineChoice.native.slowThreshold < EngineChoice.http.slowThreshold)

    var native = EngineHealth(slowThreshold: EngineChoice.native.slowThreshold,
                              slowHint: EngineChoice.native.slowHint)
    native.record(timeToFirstSound: 1.95)   // healthy for the server, bad for native
    #expect(native.status == .slow(median: 1.95))
    #expect(native.summary.contains("quitting and reopening MoxSpeak"))

    var http = EngineHealth(slowThreshold: EngineChoice.http.slowThreshold,
                            slowHint: EngineChoice.http.slowHint)
    http.record(timeToFirstSound: 1.95)
    #expect(http.status == .healthy(median: 1.95),
            "the same measurement is a healthy server and a degraded native engine")

    // And when the server really is slow, the advice is the one that fits a server.
    var degraded = EngineHealth(slowThreshold: EngineChoice.http.slowThreshold,
                                slowHint: EngineChoice.http.slowHint)
    degraded.record(timeToFirstSound: 6.0)
    #expect(degraded.summary.contains("restarting it may help"))
}

@Test func theRawValuesAreTheOnDiskFormatAndMustNotDrift() {
    // Renaming a case silently resets everyone's stored preference to the default.
    #expect(EngineChoice.native.rawValue == "native")
    #expect(EngineChoice.http.rawValue == "http")
}

// MARK: - The migration: 72 voices become 46

/// Exactly what the server offers today.
private let serverVoices = [
    "af_alloy", "af_amelia_inno", "af_aoede", "af_bella", "af_goodall_inno", "af_heart",
    "af_jadzia", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah",
    "af_sky", "af_v0", "af_v0bella", "af_v0irulan", "af_v0nicole", "af_v0sarah", "af_v0sky",
    "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
    "am_price_inno", "am_puck", "am_santa", "am_v0adam", "am_v0gurney", "am_v0michael",
    "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bf_v0emma", "bf_v0isabella",
    "bm_atten_inno", "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "bm_v0george",
    "bm_v0lewis",
    // The 26 the native engine does not ship: every one non-English, and unphonemizable
    // by the vendored MisakiSwift, which carries only the US English lexicon.
    "ef_dora", "em_alex", "em_santa", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega",
    "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi",
    "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni",
    "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
]

/// Exactly what ships in the bundle.
private let nativeVoices = Array(serverVoices.prefix(46))

@Test func theTwoVoiceListsAreTheOnesThisMigrationIsAbout() {
    #expect(serverVoices.count == 72)
    #expect(nativeVoices.count == 46)
    #expect(Set(nativeVoices).isSubset(of: Set(serverVoices)),
            "native ships a subset; nothing is native-only")
}

@Test func theOwnersStoredVoiceSurvivesTheSwitch() {
    #expect(Settings.resolveVoice(stored: "am_michael", available: serverVoices) == "am_michael")
    #expect(Settings.resolveVoice(stored: "am_michael", available: nativeVoices) == "am_michael")
}

@Test func aVoiceTheNativeEngineDoesNotShipFallsBackRatherThanBreaking() {
    // Anyone with one of the 26. The fallback has to be a voice that exists, not the
    // stored one and not nothing.
    for orphan in ["ef_dora", "zf_xiaoxiao", "jm_kumo", "pm_santa"] {
        let resolved = Settings.resolveVoice(stored: orphan, available: nativeVoices)
        #expect(resolved == Settings.defaultVoice)
        #expect(nativeVoices.contains(resolved))
    }
}

@Test func theFallbackIsThisSessionOnlyAndTheStoredVoiceComesBack() {
    // The property that makes `applyVoiceList` resolve from `settings.storedVoice` rather
    // than from the voice in use. Resolving from the voice in use would leave the user on
    // af_bella after switching back to an engine that has ef_dora — a silent, permanent
    // loss of their preference caused by a round trip they may not even remember making.
    let stored = "ef_dora"
    let onNative = Settings.resolveVoice(stored: stored, available: nativeVoices)
    #expect(onNative != stored)

    let backOnServer = Settings.resolveVoice(stored: stored, available: serverVoices)
    #expect(backOnServer == stored, "the stored preference was never overwritten")

    let ifWeHadResolvedFromTheVoiceInUse =
        Settings.resolveVoice(stored: onNative, available: serverVoices)
    #expect(ifWeHadResolvedFromTheVoiceInUse != stored,
            "this is the bug the stored-first rule avoids")
}

@Test func anUnreachableEngineDoesNotCostTheUserTheirVoice() {
    // Switching to the HTTP engine with no server running yields an empty list. That is
    // "the question cannot be asked", not "your voice is invalid".
    #expect(Settings.resolveVoice(stored: "ef_dora", available: []) == "ef_dora")
}
