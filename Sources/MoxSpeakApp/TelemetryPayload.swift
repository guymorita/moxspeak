import Foundation

/// The events MoxSpeak reports, and the only attributes any of them may carry.
///
/// ## Why this is a separate, pure type
///
/// "No text you select or copy ever leaves your Mac" is printed on the welcome window and
/// will be printed on the website. A promise like that cannot rest on every future call
/// site remembering it. So the rule is enforced here instead of intended everywhere: an
/// attribute reaches the network only if its key is on `allowedKeys` *and* its value
/// survives `sanitize`. Anything else is dropped silently — not logged, not truncated,
/// not sent under a different name.
///
/// That inverts the usual failure. A new call site that tries to attach the text being
/// spoken does not leak it; it just fails to report an attribute nobody will miss. The
/// cost is that adding a genuinely new dimension means adding its key here, deliberately,
/// which is exactly the moment to think about whether it should be sent at all.
///
/// It holds no Sentry types on purpose, so the rules can be tested without a network, a
/// DSN, or an initialized SDK — see `TelemetryPayloadTests`.
enum TelemetryEvent: String, CaseIterable, Sendable {
    case appLaunched = "app_launched"
    case speechStarted = "speech_started"
    case speechFinished = "speech_finished"
    case speechStopped = "speech_stopped"
    case speechFailed = "speech_failed"
    case voiceChanged = "voice_changed"
    case speedChanged = "speed_changed"
    case accessibilityEnabled = "accessibility_enabled"
    case firstRunCompleted = "first_run_completed"
    case updateOffered = "update_offered"
    case telemetryDisabled = "telemetry_disabled"
}

enum TelemetryPayload {

    /// Every attribute key that may ever be sent, with what it is for.
    ///
    /// Read this list as the answer to "what does MoxSpeak know about me". There is
    /// nothing here that identifies a person, a machine, a document or a website:
    ///
    /// - `app_version`, `build`, `macos`, `mac_model`, `chip` — which build, on what.
    ///   `mac_model` is a hardware generation ("Mac14,12"), not a serial number.
    /// - `engine`, `voice`, `speed` — settings, all chosen from fixed lists.
    /// - `accessibility` — whether the permission is granted, as a yes or no.
    /// - `tier` — which of the three read strategies produced the text. This is the
    ///   number that tells us whether the compatibility work is holding up.
    /// - `length_bucket` — a coarse size band, never a character count, because an exact
    ///   length is a fingerprint of a specific document.
    /// - `trigger` — hotkey or menu.
    /// - `progress_bucket` — how far through a reading somebody got, in quarters. The
    ///   one number that says whether people actually listen to whole articles.
    /// - `failed_app` — the bundle identifier of the app a read FAILED in, and only
    ///   then. It is the entire compatibility backlog in one field. It is never sent on
    ///   success, because a list of apps somebody successfully used would be a record of
    ///   what they read and when.
    /// - `reason` — a fixed vocabulary of failure causes, never an error message, which
    ///   could contain a file path or a snippet of the document.
    static let allowedKeys: Set<String> = [
        "app_version", "build", "macos", "mac_model", "chip",
        "engine", "voice", "speed", "accessibility",
        "tier", "length_bucket", "trigger", "progress_bucket",
        "failed_app", "reason",
    ]

    /// The longest an attribute value may be. Every legitimate value above is a short
    /// token; anything longer is a mistake or a leak, and both should be dropped.
    static let maximumValueLength = 64

    /// Characters an attribute value may contain: identifiers, versions, bundle ids,
    /// decimals. No spaces — every allowed value is a single token, and prose is the
    /// thing being kept out.
    private static let allowedCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+,")

    /// Filters a set of attributes down to what may be sent.
    ///
    /// Bools and numbers pass as themselves. Strings must be short and free of anything
    /// that looks like prose. Everything else — a dictionary, an array, an arbitrary
    /// object whose `description` might be anything at all — is dropped rather than
    /// stringified, because stringifying is exactly how a document ends up in a field
    /// that was supposed to hold an enum.
    static func sanitize(_ attributes: [String: Any]) -> [String: Any] {
        var clean: [String: Any] = [:]
        for (key, value) in attributes where allowedKeys.contains(key) {
            switch value {
            case let flag as Bool:
                clean[key] = flag
            case let number as Int:
                clean[key] = number
            case let number as Double:
                clean[key] = number
            case let text as String:
                guard !text.isEmpty,
                      text.count <= maximumValueLength,
                      text.unicodeScalars.allSatisfy(allowedCharacters.contains)
                else { continue }
                clean[key] = text
            default:
                continue
            }
        }
        return clean
    }

    /// A coarse size band for a piece of text. Never the exact length: the number of
    /// characters in a document is close to a fingerprint for it, and the product
    /// question — are people reading sentences or articles — is answered by the band.
    static func lengthBucket(characters: Int) -> String {
        switch characters {
        case ..<0: return "unknown"
        case 0..<200: return "xs"
        case 200..<1_000: return "s"
        case 1_000..<5_000: return "m"
        case 5_000..<20_000: return "l"
        default: return "xl"
        }
    }

    /// How far through a reading somebody got, in quarters, so "do people finish
    /// articles" has an answer that is not a timestamp.
    static func progressBucket(played: TimeInterval, total: TimeInterval) -> String {
        guard total > 0, played >= 0 else { return "unknown" }
        switch played / total {
        case ..<0.25: return "0-25"
        case ..<0.5: return "25-50"
        case ..<0.75: return "50-75"
        case ..<0.99: return "75-99"
        default: return "100"
        }
    }
}
