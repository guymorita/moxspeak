import Foundation

/// A `moxspeak://` URL, parsed into something the app can act on.
///
/// ## Why a URL scheme rather than a Raycast extension
///
/// People who use launchers want MoxSpeak on their own key, not on ours. The obvious move
/// is to build a Raycast extension, but that would cover Raycast and nothing else, take a
/// TypeScript project and a store submission, and need updating whenever their API moves.
///
/// A URL scheme is the opposite trade. It is the one automation surface every launcher on
/// macOS already speaks: Raycast script commands, Alfred workflows, Shortcuts' Open URL
/// action, Keyboard Maestro, BetterTouchTool, and `open` in any shell script. One small
/// parser here, no dependency on anybody's SDK, and nothing to keep up with.
///
/// It also costs the caller nothing, because MoxSpeak already reads the selection itself.
/// A launcher does not have to fetch the text and hand it over; it only has to say "do the
/// thing you do". That is why `moxspeak://speak` takes no arguments in the common case.
///
/// The default hotkeys are untouched and independent. This is an additional way in.
enum URLCommand: Equatable {
    /// Speak whatever is selected, or the clipboard, exactly as the hotkey does.
    case speak
    /// Speak this exact text. For callers that already have it — a Shortcuts action, a
    /// script piping something in — and do not want the selection consulted at all.
    case speakText(String)
    case pause
    case stop
    /// Move by a relative amount. Negative goes back. Launchers get the same fifteen
    /// seconds the media keys do, without spending a global shortcut on it.
    case skip(seconds: Double)

    static let scheme = "moxspeak"

    /// Matches `NowPlayingController.skipSeconds`, so the URL and the media key move by
    /// the same amount. Two different "skip" distances in one app would be a bug nobody
    /// could describe.
    static let defaultSkip: Double = 15

    /// Parses a URL, or returns nil for anything this does not recognise.
    ///
    /// Strict on purpose. A URL scheme is an interface anyone on the machine can call, so
    /// an unrecognised host does nothing rather than being coerced into the nearest
    /// match: guessing here would mean a typo in somebody's script silently starting
    /// speech instead of stopping it.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        // `moxspeak://speak` parses with "speak" as the host; `moxspeak:speak` parses it
        // as the path. Both are things people type, so both are accepted.
        // An empty host is not a missing host: `moxspeak:///stop` parses with host ""
        // and the action in the path, so `??` alone would read it as no action at all.
        let host = components.host.flatMap { $0.isEmpty ? nil : $0 }
        let action = (host ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        switch action {
        case "speak":
            let text = components.queryItems?
                .first { $0.name.lowercased() == "text" }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                self = .speakText(text)
            } else {
                self = .speak
            }
        case "pause", "toggle", "resume":
            self = .pause
        case "stop":
            self = .stop
        case "back", "rewind":
            self = .skip(seconds: -Self.defaultSkip)
        case "forward", "skip":
            let requested = components.queryItems?
                .first { $0.name.lowercased() == "seconds" }?
                .value.flatMap(Double.init)
            self = .skip(seconds: requested ?? Self.defaultSkip)
        default:
            return nil
        }
    }

    /// How long to wait before reading the selection, when the request came from a URL.
    ///
    /// A launcher is the frontmost application at the moment it runs your script, and its
    /// window is still dismissing. Reading the selection immediately asks Raycast what is
    /// selected in Raycast, which is nothing, and the user gets their clipboard instead of
    /// the paragraph they had highlighted.
    ///
    /// Only the selection-reading cases wait. Pause and stop act on what is already
    /// playing and have no reason to care who is frontmost, so they stay instant.
    var focusSettlingDelay: TimeInterval {
        switch self {
        case .speak: return 0.25
        case .speakText, .pause, .stop, .skip: return 0
        }
    }

    var logName: String {
        switch self {
        case .speak: return "speak"
        case .speakText(let text): return "speak \(text.count) characters of supplied text"
        case .pause: return "pause"
        case .stop: return "stop"
        case .skip(let seconds):
            return "skip \(seconds > 0 ? "forward" : "back") \(abs(Int(seconds)))s"
        }
    }
}
