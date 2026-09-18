import Foundation

/// Erasing everything MoxSpeak leaves on the machine outside its own bundle.
///
/// ## What this touches, exhaustively
///
/// Two things, and they are the *only* two. Everything the speech engine needs — the
/// Kokoro weights, the 46 voice vectors, the MisakiSwift lexicon, MLX's Metal library —
/// ships inside `MoxSpeak.app` (see `build-app.sh`), so dragging the app to the Trash
/// takes 218 MB of assets with it. What survives is what macOS keeps for every app:
///
/// 1. **The preferences domain `com.moxspeak.menubar`** — the stored voice, speed and
///    engine, plus the status item position AppKit writes there itself. Backed by
///    `~/Library/Preferences/com.moxspeak.menubar.plist`, owned and cached by `cfprefsd`.
///    Removed through `UserDefaults`, never by deleting the file: `cfprefsd` holds the
///    domain in memory and would write its cached copy straight back out.
/// 2. **`~/Library/Logs/MoxSpeak.log`** — see `AppLog`.
///
/// There is no Application Support directory (`NativeModelAssets` *reads* one as a
/// hand-installed override and never creates it), no cache, no first-run download, no
/// temporary file, no login item and no launch agent. A `grep` for every persistent
/// write in `Sources/MoxSpeakApp`, `MoxSpeakCore` and `MoxSpeakNative` finds exactly
/// `UserDefaults` and `AppLog.write`, which is the pair above.
///
/// ## What is left afterwards, measured
///
/// Verified on a copy of the bundle given its own identifier, so nothing else on the
/// machine could write into the domain while it was watched: after a reset the domain is
/// empty (`defaults read` answers "does not exist"), the log file is gone, and what
/// physically survives is **42 bytes** — `~/Library/Preferences/com.moxspeak.<id>.plist`
/// holding `{}`. `cfprefsd` owns that file and keeps it; deleting it out from under a
/// running `cfprefsd` only invites it to write its cached copy back. An empty property
/// list is the floor, and it is the same thing every macOS app that has ever stored a
/// preference leaves behind.
///
/// ## What this deliberately cannot touch
///
/// The Accessibility approval behind select-to-speak. That grant lives in the system TCC
/// database, is keyed to the app's Developer ID signing identity, and is not writable by
/// the app it was granted to — deliberately, because an app that could revoke or restore
/// its own permissions would be a hole rather than a feature. So the confirmation below
/// says where it is and who removes it, instead of implying a clean slate this cannot
/// deliver.
enum Reset {

    // MARK: - Words
    //
    // Kept here rather than inline in the alert so the honesty of the wording is a thing
    // tests can assert. `confirmationDetail` in particular has one job it must never stop
    // doing: telling the user about the one permission MoxSpeak cannot take back.

    /// The menu item. Named for what the user gets, not for `removePersistentDomain`.
    static let menuTitle = "Reset MoxSpeak…"

    static let menuDetail = "Forget the voice, speed and engine you chose and delete "
                          + "MoxSpeak's log file, so that moving MoxSpeak to the Trash "
                          + "leaves nothing of it behind."

    static let confirmationTitle = "Reset MoxSpeak?"

    static let confirmationDetail = """
        MoxSpeak will forget the voice, speed and engine you chose, and delete its log \
        file at ~/Library/Logs/MoxSpeak.log. It will then behave exactly as it did the \
        first time you opened it.

        Those two are the only things MoxSpeak keeps outside the app itself, so resetting \
        and then moving MoxSpeak to the Trash leaves nothing of it on this Mac. MoxSpeak \
        stops writing to its log until you next open it, so the file it just deleted does \
        not come straight back.

        One thing this cannot do for you: if you turned on Select-to-Speak, macOS \
        remembers that approval, not MoxSpeak, and an app is not allowed to withdraw its \
        own permissions. Remove it yourself in System Settings → Privacy & Security → \
        Accessibility.

        This cannot be undone.
        """

    /// The button that does it. Not "OK" — a destructive button should say what it does,
    /// so a half-read dialog dismissed on reflex is still dismissed knowingly.
    static let confirmButton = "Reset"
    static let cancelButton = "Cancel"

    // MARK: - Doing it

    /// What actually happened, in enough detail to be written down honestly.
    ///
    /// Both halves are reported separately because they fail separately: a read-only
    /// Logs directory does not stop the preferences going, and neither should be reported
    /// as the other.
    struct Outcome: Equatable {
        var preferencesCleared: Bool
        /// Anything still in the domain after the attempt. Non-empty means the erase did
        /// not do what it claims, which the user needs to hear about rather than a
        /// cheerful "done".
        var leftoverKeys: [String]
        var logCleared: Bool
        var logProblem: String?

        var isClean: Bool { preferencesCleared && leftoverKeys.isEmpty && logCleared }

        /// One line for the status area. Reports the failure if there was one, because a
        /// reset that half worked is exactly the state a user must not be left believing
        /// is a whole one.
        var summary: String {
            if isClean { return "Reset — MoxSpeak is back to how it starts" }
            var problems: [String] = []
            if !preferencesCleared || !leftoverKeys.isEmpty {
                problems.append("settings could not all be cleared")
            }
            if !logCleared { problems.append(logProblem ?? "the log could not be deleted") }
            return "Reset was incomplete — " + problems.joined(separator: "; ")
        }
    }

    /// Empties a preferences domain and reports what is left.
    ///
    /// `domain` is `Bundle.main.bundleIdentifier`, which is nil when the binary is run
    /// straight out of `.build` with no Info.plist around it. That is a normal state
    /// during development, not an error, so it falls back to removing the keys this app
    /// is known to write. The domain sweep is the thorough one — it also takes AppKit's
    /// own `NSStatusItem Preferred Position` key, which we never wrote and would
    /// otherwise never think to remove — so it is preferred whenever there is a domain to
    /// sweep.
    @discardableResult
    static func erasePreferences(in defaults: UserDefaults,
                                 domain: String?,
                                 knownKeys: [String] = Settings.allKeys)
        -> (cleared: Bool, leftoverKeys: [String]) {

        if let domain, !domain.isEmpty {
            defaults.removePersistentDomain(forName: domain)
        } else {
            for key in knownKeys { defaults.removeObject(forKey: key) }
        }

        // Asked, not assumed. `removePersistentDomain` is documented to empty the domain
        // and there is still no reason to take its word for it — this is the check that
        // turns "we called the right function" into "the values are gone".
        let leftover = knownKeys.filter { defaults.object(forKey: $0) != nil }
        return (leftover.isEmpty, leftover)
    }

    /// Deletes a file if it is there.
    ///
    /// Already absent counts as success: the caller asked for the file to be gone, and it
    /// is gone. Reporting "no such file" as a failure would make a second reset look
    /// broken.
    static func eraseFile(at url: URL?, using manager: FileManager = .default)
        -> (cleared: Bool, problem: String?) {

        guard let url else { return (false, "MoxSpeak could not work out where its log is") }
        guard manager.fileExists(atPath: url.path) else { return (true, nil) }
        do {
            try manager.removeItem(at: url)
            return (true, nil)
        } catch {
            return (false, "the log at \(url.path) could not be deleted — "
                         + error.localizedDescription)
        }
    }
}
