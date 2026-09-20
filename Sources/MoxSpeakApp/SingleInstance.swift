import AppKit

/// Makes sure only one MoxSpeak is running.
///
/// ## Why this matters more than it sounds
///
/// Two copies both register ⌃⌥S. Carbon gives the shortcut to whichever asked first and
/// returns an error to the other, so the second copy is running, showing an icon in the
/// menu bar, and silently not responding to the only key anybody presses. The symptom is
/// "the shortcut stopped working", which is the hardest kind of bug to report and the
/// easiest to blame on the app being broken.
///
/// It is easy to reach. Open the disk image, run MoxSpeak from it to try it, then drag it
/// to Applications and run that too. Or leave a build in Downloads. Nothing warns you,
/// because two copies of the same app is a perfectly normal thing for macOS to allow.
enum SingleInstance {

    /// Another running copy of this app, if there is one.
    ///
    /// Compared by bundle identifier rather than by path, because the whole point is to
    /// catch two copies living in different places. Never matches this process.
    static func other() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == identifier && $0.processIdentifier != mine
        }
    }

    /// Returns true when this process should stop, having found an older copy already
    /// running, and leaves a line in the log saying where that copy lives.
    ///
    /// The *newer* process yields, not the older one. The older copy owns the hotkeys and
    /// may well be speaking; killing it to make way for a duplicate would interrupt
    /// somebody mid-article to achieve nothing. Yielding is also silent on purpose — an
    /// alert here would fire every time a stray copy is double-clicked, and the honest
    /// response to "you already have this open" is to do nothing at all.
    static func shouldYield() -> Bool {
        guard Bundle.main.bundleIdentifier != nil else {
            // No bundle: a `swift build` binary during development. Two of those is a
            // deliberate act, and refusing to start would be infuriating.
            return false
        }
        guard let existing = other() else { return false }
        let where_ = existing.bundleURL?.path ?? "an unknown location"
        AppLog.write("launch: MoxSpeak is already running from \(where_) "
                     + "(pid \(existing.processIdentifier)) — this copy is exiting so the "
                     + "two do not fight over the shortcut")
        return true
    }
}
