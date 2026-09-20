import AppKit
import MoxSpeakCore

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

    /// The engine currently in use, and the session built around it. Replaced wholesale
    /// when the user picks a different engine — see `selectEngine`.
    private var runtime: EngineRuntime
    private var engineChoice: EngineChoice

    /// Bumped every time the engine changes. In-flight work carries the value it was
    /// started under, so a voice list (or a warm-up) that arrives after the user has
    /// moved on is discarded rather than applied to an engine it does not describe.
    /// Without it, a 30-second HTTP timeout landing after a switch to native would
    /// overwrite the native voice list with a failure that has nothing to do with it.
    private var engineGeneration = 0

    private let hotkeys = HotkeyManager()
    private let nowPlaying = NowPlayingController()
    private var menuBar: MenuBarController?

    /// What is actually registered, per action. The menu, the status hint and the
    /// shortcuts window all read their combinations from here rather than from a literal,
    /// so a rebinding cannot leave one of them telling the user about a key that no longer
    /// does anything.
    private var hotkeyBindings: [HotkeyAction: Hotkey] = [:]
    private var shortcuts: ShortcutsWindowController?
    /// Held for the life of the app rather than the life of the window: it is shown once
    /// and then never again, but it must not be deallocated while it is on screen.
    private var welcome: WelcomeWindowController?

    /// A fresh `PlaybackEngine` per utterance rather than one reused for the app's
    /// lifetime. `AVAudioPlayerNode.stop()` and the pending-buffer count that
    /// `waitForDrain()` reads are easy to get out of step when a queue is torn down
    /// mid-playback, and a replaced utterance tears one down mid-playback every time.
    /// Building a new engine is a few milliseconds and makes "replace what's playing"
    /// exactly as simple as it sounds.
    private var engine: PlaybackEngine?
    private var playback: Task<Void, Never>?

    /// Rebuilt per engine: what counts as slow, and what a user could do about it, are
    /// both engine-specific. See `EngineChoice.slowThreshold`.
    private var health: EngineHealth

    /// Persisted across launches. The values below are already the *resolved* ones —
    /// see `Settings` for why what was stored and what is safe to use are not the same
    /// question.
    private let settings: Settings
    private var voice: String
    private var rate: Float

    private var isPlaying = false
    /// Set when something went wrong with the current utterance, cleared when a new one
    /// starts. Sticky on purpose: an error that vanished after two seconds would be an
    /// error the user never saw.
    private var lastError: String?
    private var idleNote = "Ready"
    /// True while a speak-shortcut read is in flight. Tier 2 saves and restores the pasteboard, and
    /// two of those running at once would restore each other's work over the user's real
    /// clipboard, so a second press during a read is dropped and logged.
    private var isReadingSelection = false
    private var hotkeyWarning: String?
    /// A standing problem with the engine itself — the native model failing to load, say.
    /// Sits in the menu next to the hotkey warning rather than vanishing into the log.
    private var engineWarning: String?

    init(port: Int, settings: Settings = Settings()) {
        self.port = port
        self.settings = settings

        // The engine is settled before anything else, because everything else depends on
        // it: which voices exist, how large a chunk may be, and whether text is
        // normalized here or by a server. `resolveEngine` always answers with an engine
        // this build actually has.
        let choice = Settings.resolveEngine(stored: settings.storedEngine)
        self.engineChoice = choice
        self.runtime = EngineRuntime(choice: choice, port: port)
        self.health = EngineHealth(slowThreshold: choice.slowThreshold,
                                   slowHint: choice.slowHint)

        // The voice cannot be checked against the engine's list yet — nothing has been
        // asked of the engine at this point — so it is resolved again in `loadVoices`
        // once there is a list to check it against. The speed needs no such list: the
        // control offers the whole range `PlaybackEngine` will honour, so resolving it
        // is just validating and clamping — settled here and for good.
        self.voice = Settings.resolveVoice(stored: settings.storedVoice, available: [])
        self.rate = Settings.resolveRate(stored: settings.storedRate)
    }

    // MARK: - Launch

    func start() {
        let menuBar = MenuBarController(actions: .init(
            speak: { [weak self] in self?.speakClipboard() },
            togglePause: { [weak self] in self?.togglePause() },
            stop: { [weak self] in self?.stop() },
            selectVoice: { [weak self] in self?.selectVoice($0) },
            selectRate: { [weak self] in self?.selectRate($0) },
            selectEngine: { [weak self] in self?.selectEngine($0) },
            enableSelectToSpeak: { [weak self] in self?.enableSelectToSpeak() },
            openShortcuts: { [weak self] in self?.openShortcuts() },
            reset: { [weak self] in self?.resetEverything() },
            openDownloadPage: { NSWorkspace.shared.open(UpdateCheck.downloadPage) },
            isLaunchAtLoginEnabled: { LaunchAtLogin.isEnabled },
            setLaunchAtLoginEnabled: { [weak self] on in
                let settled = LaunchAtLogin.set(on)
                if !settled {
                    self?.menuBar?.flash("Allow MoxSpeak in System Settings, Login Items",
                                         seconds: 5)
                }
            },
            isTelemetryEnabled: { [weak self] in self?.settings.isTelemetryEnabled ?? true },
            setTelemetryEnabled: { [weak self] on in
                guard let self else { return }
                Telemetry.setEnabled(on, settings: self.settings)
            },
            openPrivacy: {
                if let url = URL(string: "https://guymorita.github.io/moxspeak/#privacy") {
                    NSWorkspace.shared.open(url)
                }
            },
            menuWillOpen: { [weak self] in self?.refreshSelectToSpeak() },
            quit: { NSApplication.shared.terminate(nil) }
        ))
        self.menuBar = menuBar
        menuBar.setVoices([], selected: voice, note: "Loading voices…")
        menuBar.setSelectedRate(rate)
        menuBar.setEngines(EngineChoice.allCases, selected: engineChoice, port: port)
        refreshSelectToSpeak()

        installHotkeys()

        nowPlaying.onTogglePlayPause = { [weak self] in self?.togglePause() }
        nowPlaying.onStop = { [weak self] in self?.stop() }
        nowPlaying.activate()

        Telemetry.start(settings: settings)
        Telemetry.runSelfTestIfAsked(settings: settings)
        checkForUpdateIfDue()
        Telemetry.record(.appLaunched, [
            "engine": engineChoice.rawValue,
            "accessibility": SelectionReader.isTrusted,
            "voice": voice,
            "speed": Double(rate),
        ])

        refresh()
        // Deferred a turn: AppKit has not placed the status item in the menu bar yet at
        // this point, so asking where it is now gives an answer that is wrong rather than
        // missing. `statusItemFrame` refuses to return a frame that is not in the menu
        // bar, so the worst case here is a sensible fallback rather than a window in the
        // wrong corner — but waiting means the common case is right.
        DispatchQueue.main.async { [weak self] in self?.showWelcomeIfFirstRun() }
        AppLog.write("app: started on the \(engineChoice.logName) engine — "
                     + "\(engineChoice.menuTitle(port: port))")
        AppLog.write("settings: restored voice \(voice) at \(rate)× "
                     + "(stored: engine=\(settings.storedEngine ?? "none"), "
                     + "voice=\(settings.storedVoice ?? "none"), "
                     + "speed=\(settings.storedRate.map { "\($0)" } ?? "none"))")
        beginEngine()
    }

    /// Asks GitHub whether there is a newer release, at most once a day.
    ///
    /// Detached and unawaited: nothing about launching, speaking or the menu may wait on
    /// a network call. Every failure path ends in silence — no alert, no retry, no row.
    /// Somebody offline must not be able to tell that this ran.
    ///
    /// The timestamp is written before the request rather than after, so a check that
    /// hangs or crashes the process cannot produce an app that asks GitHub on every
    /// single launch forever.
    private func checkForUpdateIfDue() {
        let installed = AppVersion.read().shortVersion
        guard installed != nil else { return }   // a `swift build` binary has no version
        if let last = settings.lastUpdateCheck,
           Date().timeIntervalSince(last) < UpdateCheck.interval {
            return
        }
        settings.lastUpdateCheck = Date()

        Task { [weak self] in
            let latest = await UpdateCheck().latestRelease()
            guard let update = UpdateCheck.update(installed: installed, latest: latest)
            else {
                if latest != nil {
                    AppLog.write("update: \(installed ?? "?") is current (latest \(latest!))")
                }
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.menuBar?.setUpdateAvailable(update.description)
                AppLog.write("update: \(update) is available, running \(installed ?? "?")")
                Telemetry.record(.updateOffered, ["app_version": installed ?? ""])
            }
        }
    }

    /// Shows the welcome window the first time MoxSpeak is opened, and never again.
    ///
    /// The flag is written when the window closes rather than when it opens: a first
    /// launch that is force-quit part way through should get another go, not leave
    /// somebody holding a menu bar app whose shortcut they never learned.
    private func showWelcomeIfFirstRun() {
        guard !settings.hasCompletedFirstRun else { return }
        // `LSUIElement` apps launch without activating, so a window shown here would open
        // behind whatever the user is looking at. Becoming a regular app for the duration
        // puts it in front — and returns to accessory afterwards, because a Dock icon is
        // exactly what this app promises not to have.
        NSApp.setActivationPolicy(.regular)
        let speakHotkey = hotkeyBindings[.speak] ?? HotkeyAction.speak.defaultHotkey
        let controller = WelcomeWindowController(
            shortcutLabel: speakHotkey.label,
            shortcutWords: speakHotkey.spelledOut,
            actions: .init(
                requestAccessibility: {
                    SelectionReader.requestPermission()
                    return SelectionReader.isTrusted
                },
                isAccessibilityTrusted: { SelectionReader.isTrusted },
                finish: { [weak self] launchAtLogin in
                    self?.finishFirstRun(launchAtLogin: launchAtLogin)
                }))
        welcome = controller
        controller.show(under: menuBar?.statusItemFrame)
        AppLog.write("welcome: first launch — showing the welcome window")
    }

    private func finishFirstRun(launchAtLogin: Bool) {
        settings.hasCompletedFirstRun = true
        Telemetry.record(.firstRunCompleted, ["accessibility": SelectionReader.isTrusted])
        NSApp.setActivationPolicy(.accessory)
        if LaunchAtLogin.isAvailable {
            let settled = LaunchAtLogin.set(launchAtLogin)
            AppLog.write("welcome: launch at login \(launchAtLogin ? "on" : "off")"
                         + (settled ? "" : " — the system did not accept it"))
        }
        refreshSelectToSpeak()
        AppLog.write("welcome: finished — accessibility=\(SelectionReader.isTrusted)")
    }

    /// Registers all three shortcuts, resolving each against what was stored first.
    ///
    /// The resolving step is where the macOS 15 defect is actually repaired for an
    /// existing user. A binding stored by an older MoxSpeak is ⌥⇧-only and cannot fire;
    /// `Settings.resolveHotkey` moves it to the combination that can, says so in the log,
    /// and asks for the new value to be written back — so the change is traceable, happens
    /// once, and never leaves anybody sitting on a shortcut that the system refuses to
    /// deliver. See `Hotkey` for the restriction itself.
    private func installHotkeys() {
        var problems: [String] = []

        for action in HotkeyAction.allCases {
            let resolution = Settings.resolveHotkey(stored: settings.storedHotkey(action),
                                                    action: action)
            if let note = resolution.note { AppLog.write("hotkey: \(note)") }
            if resolution.shouldRestore {
                settings.setStoredHotkey(resolution.hotkey.storageString, for: action)
            }

            do {
                try hotkeys.register(resolution.hotkey,
                                     for: action,
                                     handler: handler(for: action))
                hotkeyBindings[action] = resolution.hotkey
            } catch {
                problems.append("\(error)")
                // Still shown in the menu and the shortcuts window: a user cannot fix a
                // shortcut they cannot see, and this is the binding they would be fixing.
                hotkeyBindings[action] = resolution.hotkey
            }
        }

        menuBar?.setHotkeys(hotkeyBindings)

        // Said out loud once per launch for anyone still on the shipped combinations,
        // because the change is otherwise invisible from the log alone: the user pressed
        // ⌥⇧S for months, it stopped working without a word from macOS, and now it is a
        // different key. Suppressed for anyone who has chosen their own — they know what
        // they picked, and repeating the history at them every launch is noise.
        if HotkeyAction.allCases.allSatisfy({ settings.storedHotkey($0) == nil }) {
            let labels = HotkeyAction.allCases
                .map { hotkeyBindings[$0]?.label ?? $0.defaultHotkey.label }
                .joined(separator: ", ")
            AppLog.write("hotkey: on the default shortcuts (\(labels)) — the old ⌥⇧ "
                         + "combinations were dropped because macOS 15 and later refuse "
                         + "to deliver shortcuts held with only Option and Shift")
        }

        guard !problems.isEmpty else { return }

        // A hotkey that quietly does nothing is the worst possible outcome here: the user
        // presses it, nothing happens, and there is no way to tell a taken shortcut from
        // a broken app. So it goes in the menu permanently *and* announces itself once.
        hotkeyWarning = problems.joined(separator: "; ")
        menuBar?.flash("Hotkey unavailable. See the menu.", seconds: 4)
        AppLog.write("hotkey: \(hotkeyWarning ?? "")")
    }

    /// What each shortcut does. Held in one place so registering and re-registering cannot
    /// disagree about which key speaks and which one stops.
    private func handler(for action: HotkeyAction) -> @MainActor () -> Void {
        switch action {
        case .speak: return { [weak self] in self?.speakText() }
        case .pause: return { [weak self] in self?.togglePause() }
        case .stop: return { [weak self] in self?.stop() }
        }
    }

    // MARK: - Rebinding

    private func openShortcuts() {
        let window = shortcuts ?? ShortcutsWindowController(actions: .init(
            current: { [weak self] in self?.hotkeyBindings ?? [:] },
            rebind: { [weak self] action, hotkey in
                self?.rebind(action, to: hotkey) ?? "MoxSpeak is shutting down"
            },
            restoreDefaults: { [weak self] in self?.restoreDefaultHotkeys() ?? [:] }
        ))
        shortcuts = window
        window.show()
    }

    /// Puts one action on a new combination, or explains why it cannot be.
    ///
    /// Nil means it took. Anything else is a sentence for the user, and the binding is
    /// exactly what it was a moment ago — `HotkeyManager.register` registers the new
    /// combination before releasing the old one, so a failure costs nothing.
    ///
    /// Persisted only after it is in force. Writing first would mean a combination that
    /// Carbon refused still coming back at the next launch.
    private func rebind(_ action: HotkeyAction, to hotkey: Hotkey) -> String? {
        do {
            try hotkeys.register(hotkey, for: action, handler: handler(for: action))
        } catch let failure as HotkeyManager.Failure {
            AppLog.write("hotkey: could not rebind \(action.rawValue) to "
                         + "\(hotkey.label) — \(failure)")
            return failure.explanation
        } catch {
            AppLog.write("hotkey: could not rebind \(action.rawValue) to "
                         + "\(hotkey.label) — \(error)")
            return "\(error)"
        }

        hotkeyBindings[action] = hotkey
        settings.setStoredHotkey(hotkey.storageString, for: action)
        menuBar?.setHotkeys(hotkeyBindings)
        clearHotkeyWarningIfEverythingIsBound()
        refresh()
        AppLog.write("hotkey: \(action.rawValue) rebound to \(hotkey.label) and stored")
        return nil
    }

    /// Back to the shipped three, and forget what was stored — a stored value identical to
    /// the default is a value that would survive a change of default, which is not what
    /// "use the defaults" means.
    @discardableResult
    private func restoreDefaultHotkeys() -> [HotkeyAction: Hotkey] {
        for action in HotkeyAction.allCases {
            let fallback = action.defaultHotkey
            do {
                try hotkeys.register(fallback, for: action, handler: handler(for: action))
                hotkeyBindings[action] = fallback
                settings.setStoredHotkey(nil, for: action)
            } catch {
                AppLog.write("hotkey: could not restore the default \(action.rawValue) "
                             + "shortcut \(fallback.label) — \(error)")
            }
        }
        menuBar?.setHotkeys(hotkeyBindings)
        clearHotkeyWarningIfEverythingIsBound()
        refresh()
        AppLog.write("hotkey: restored the default shortcuts")
        return hotkeyBindings
    }

    /// The standing warning is about shortcuts that would not register. Once every action
    /// holds a live registration there is nothing left to warn about, and leaving the row
    /// up would be the menu reporting a problem the user has already fixed.
    private func clearHotkeyWarningIfEverythingIsBound() {
        let allBound = HotkeyAction.allCases.allSatisfy { hotkeys.hotkey(for: $0) != nil }
        if allBound { hotkeyWarning = nil }
    }

    // MARK: - Engines

    /// Everything that has to happen when an engine starts being the engine: find out
    /// what voices it has, re-resolve the stored preference against them, and pay the
    /// model-load cost before the user does.
    ///
    /// Sequential, not concurrent: the warm-up has to be handed the voice the user will
    /// actually be speaking in, and that is not known until the list has come back.
    private func beginEngine() {
        engineGeneration += 1
        let generation = engineGeneration
        Task { [weak self] in
            await self?.loadVoices(generation: generation)
            await self?.warmUpEngine(generation: generation)
        }
    }

    /// Switches engines under a running app. Takes effect immediately — no restart.
    ///
    /// Anything playing is stopped rather than allowed to finish. The chunks still queued
    /// were synthesized by the engine being replaced, and the two engines differ in voice
    /// inventory, chunk size and prosody; letting the tail play would mean the app is
    /// audibly using an engine the menu says it is not.
    /// `persist: false` is for the one caller that must not write anything back: a reset
    /// has just emptied the preferences domain, and storing the engine it is switching
    /// *to* would put the first key straight back into a domain the user asked to be
    /// empty. The switch itself is identical either way.
    private func selectEngine(_ choice: EngineChoice, persist: Bool = true) {
        guard choice != engineChoice else { return }

        let wasPlaying = isPlaying
        teardownPlayback()
        if wasPlaying { nowPlaying.clear() }

        engineChoice = choice
        if persist { settings.storedEngine = choice.rawValue }
        runtime = EngineRuntime(choice: choice, port: port)
        // Neither what counts as slow nor anything measured about the old engine carries
        // over. Timings from a 2-second server say nothing about a 0.35-second one.
        health = EngineHealth(slowThreshold: choice.slowThreshold, slowHint: choice.slowHint)
        engineWarning = nil
        lastError = nil
        idleNote = wasPlaying ? "Stopped. Switched to \(choice.shortName)." : "Ready"

        menuBar?.setSelectedEngine(choice)
        menuBar?.setVoices([], selected: voice, note: "Loading voices…")

        // The two things a provider swap is supposed to change, written down at the
        // moment it happens. `SpeechSession` reads both once at construction, so this
        // line is the evidence that a new session was actually built rather than the old
        // one reused — which would leave the previous engine's chunk size and
        // normalization in force against the new engine.
        AppLog.write("engine: switched to \(choice.logName) — \(choice.menuTitle(port: port)); "
                     + "chunk cap \(runtime.session.characterCap) characters, "
                     + "text normalization \(runtime.session.normalizesText ? "on" : "off")")
        refresh()
        beginEngine()
    }

    private func loadVoices(generation: Int) async {
        let runtime = self.runtime
        let choice = runtime.choice
        do {
            let voices = try await runtime.provider.listVoices()
            guard generation == engineGeneration else {
                AppLog.write("voices: a \(choice.logName) voice list arrived after the "
                             + "engine changed — discarded")
                return
            }
            health.markReachable()
            applyVoiceList(voices.map(\.id), engine: choice)
            menuBar?.setVoices(voices, selected: voice, note: nil)
            AppLog.write("voices: the \(choice.logName) engine offers \(voices.count)")
        } catch {
            guard generation == engineGeneration else { return }
            // Reachable-but-unreadable and not-there-at-all are different problems with
            // different fixes, and reporting the first as the second would send the user
            // to restart an engine that is running fine.
            if error is DecodingError {
                health.markReachable()
                menuBar?.setVoices([], selected: voice,
                                   note: "Voice list unreadable. Using \(voice).")
            } else {
                health.markUnreachable(choice.unreachableReason(port: port))
                menuBar?.setVoices([], selected: voice, note: choice.voiceListUnavailableNote)
            }
            AppLog.write("voices: the \(choice.logName) engine's list failed — \(error)")
        }
        refresh()
    }

    /// Re-resolves the *stored* voice against the list this engine actually offers, and
    /// says out loud when the answer is not what was stored.
    ///
    /// Resolving from `settings.storedVoice` rather than from the voice currently in use
    /// is the whole point, and it matters at exactly one moment: an engine change. The
    /// server offers 72 voices; the native engine ships 29, all English, because the
    /// vendored MisakiSwift carries only the US English lexicon and the rest could
    /// not be phonemized anyway. So a stored non-English voice becomes unavailable the
    /// moment the engine changes — and has to come back when it changes again.
    /// Re-resolving from the voice in use would make the first fallback permanent for the
    /// rest of the session, quietly.
    ///
    /// Nothing is written back either way. The stored preference is left exactly as the
    /// user set it, so an engine that has it again restores it; overwriting here would
    /// turn a temporary absence into a permanent forgetting.
    private func applyVoiceList(_ available: [String], engine: EngineChoice) {
        let stored = settings.storedVoice?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = Settings.resolveVoice(stored: stored, available: available)
        let previous = voice
        voice = resolved

        guard let stored, !stored.isEmpty else { return }

        if resolved != stored {
            // Both the log and the menu bar. A user whose voice changed under them must
            // be able to find out why without being asked to read a log, and must still
            // be able to find out later if they missed the flash.
            AppLog.write("settings: stored voice \(stored) is not among the "
                         + "\(available.count) voices the \(engine.logName) engine offers "
                         + "— speaking as \(resolved) this session; \(stored) stays saved "
                         + "and returns on an engine that has it")
            menuBar?.flash("\(stored) isn't on this engine. Using \(resolved).", seconds: 5)
        } else if previous != stored {
            AppLog.write("settings: stored voice \(stored) is available on the "
                         + "\(engine.logName) engine — restored")
        }
    }

    /// Loads the model before the first hotkey press does. No-op for engines that are
    /// somebody else's process.
    private func warmUpEngine(generation: Int) async {
        guard generation == engineGeneration else { return }
        let runtime = self.runtime
        let voice = self.voice
        do {
            guard let seconds = try await runtime.warmUp(voice: voice) else { return }
            guard generation == engineGeneration else { return }
            AppLog.write(String(format: "engine: %@ warmed up in %.2fs (voice %@)",
                                runtime.choice.logName, seconds, voice))
        } catch {
            guard generation == engineGeneration else { return }
            // Not fatal on its own — `synthesize` would try again and fail loudly — but a
            // warm-up that failed means the first press is going to fail too, and saying
            // so now is the difference between a puzzling silence and a known problem.
            engineWarning = "The \(runtime.choice.shortName.lowercased()) engine did not "
                          + "load — \(Self.describe(error))"
            AppLog.write("engine: \(runtime.choice.logName) warm-up failed — \(error)")
            refresh()
        }
    }

    // MARK: - Commands

    /// The speak shortcut. One shortcut, three tiers, and the user never picks between
    /// them.
    ///
    /// 1. Accessibility reads the selection out of the focused app. Instant, and the
    ///    clipboard is never touched.
    /// 2. Accessibility came back empty, so the focused app is asked to copy and the
    ///    clipboard is put back afterwards. This is what reaches Electron editors and
    ///    anything else with a threadbare accessibility tree.
    /// 3. No Accessibility permission: read the clipboard, exactly as MoxSpeak has always
    ///    done with no permissions at all.
    ///
    /// Which tier ran is written to the log every single time. A user who believes they
    /// are using select-to-speak and is silently on some other path will hear the *wrong
    /// text*, which is a failure that announces itself as a success. That is precisely
    /// the class of bug this project refuses to ship.
    ///
    /// The log also names the frontmost application, because a report that says only
    /// "tier 2, nothing selected" cannot be acted on — it could be any app on the
    /// machine. Captured here, synchronously, and not inside `readAndSpeak`: tier 2 waits
    /// on another process, and focus can move in that gap, so reading it late would risk
    /// blaming whatever app happened to be frontmost when the log line was written rather
    /// than the one the user actually pressed the hotkey in.
    func speakText() {
        let appLabel = Self.frontmostAppLabel()

        // Tier 2 waits on another process to service a keystroke, so the read is async.
        // Re-entrance is dropped rather than queued: two overlapping reads would both be
        // saving and restoring the same pasteboard, and the loser would restore the
        // winner's copy over the user's real clipboard.
        guard !isReadingSelection else {
            AppLog.write("speak: ignored — a selection read is already in flight")
            return
        }
        isReadingSelection = true
        Task { [weak self] in
            defer { self?.isReadingSelection = false }
            await self?.readAndSpeak(frontmost: appLabel)
        }
    }

    /// The frontmost application, formatted for the log: name and bundle identifier
    /// together, because the name alone is ambiguous (which of a user's several
    /// Terminal-like apps?) and the bundle identifier alone means nothing to a person
    /// reading the log by eye.
    private static func frontmostAppLabel() -> String {
        describeFrontmost(name: NSWorkspace.shared.frontmostApplication?.localizedName,
                          bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// The formatting rule, with the world passed in so it can be checked without a real
    /// frontmost application — mirrors why `SelectionReader.decide` takes its world as
    /// arguments rather than reading it live. `nonisolated` because it touches nothing
    /// of `AppController`'s state and has no business demanding the main actor just
    /// because the type it lives on does.
    nonisolated static func describeFrontmost(name: String?, bundleID: String?) -> String {
        "\(name ?? "an unknown app") (\(bundleID ?? "no bundle id"))"
    }

    /// The menu's "Speak Clipboard" item.
    ///
    /// Deliberately *not* the three-tier path. Clicking a menu makes MoxSpeak the focused
    /// application, so there is no longer another app's selection to read and no app to
    /// usefully send ⌘C to — the only honest thing this item can read is the clipboard,
    /// which is what its title says it reads.
    func speakClipboard() {
        menuBar?.setSelectToSpeak(active: SelectionReader.isTrusted)
        guard let text = SelectionReader.clipboardText() else {
            menuBar?.flash("Clipboard is empty")
            idleNote = "Nothing to speak. The clipboard holds no text."
            lastError = nil
            refresh()
            AppLog.write("speak: source=clipboard (tier 3, menu) — the clipboard holds no text")
            return
        }
        AppLog.write("speak: source=clipboard (tier 3, menu) — "
                     + "read the clipboard because the menu was the thing clicked")
        speak(text)
    }

    private func readAndSpeak(frontmost appLabel: String) async {
        let reading = await SelectionReader.read()

        // Trust is re-read on every press rather than cached at launch, because it is
        // not ours to cache: the user can grant or revoke it in System Settings while
        // this process runs, and macOS does not tell us when they do.
        menuBar?.setSelectToSpeak(active: reading.isTrusted)

        AppLog.write("speak: source=\(reading.source.rawValue) "
                     + "(tier \(reading.source.tier)) from \(appLabel) — \(reading.reason)")

        guard let text = reading.text else {
            // Non-modal, self-clearing, and it says which of the things happened —
            // nothing selected, a selection that is not text, or no clipboard at all.
            menuBar?.flash(reading.flash)
            idleNote = "Nothing to speak. \(reading.note)"
            lastError = nil
            refresh()
            AppLog.write("speak: nothing to say from \(appLabel) — \(reading.note)")
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
            engine = try PlaybackEngine(format: runtime.provider.outputFormat)
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
        AppLog.write("speak: \(text.count) characters in \(voice) at \(rate)× "
                     + "on the \(engineChoice.logName) engine")

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
        settings.storedVoice = id
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
        // The slider and the exact-value field both clamp before calling this, but a
        // second clamp here costs nothing and means this method's own contract does not
        // depend on every future caller remembering to.
        let value = SpeedControl.clamped(value)
        rate = value
        settings.storedRate = value
        // TimePitch applies this instantly and pitch-corrected, so the current utterance
        // changes speed under the user's ear with no re-synthesis. That immediacy is the
        // whole reason speed lives on playback rather than on the request.
        engine?.rate = value
        menuBar?.setSelectedRate(value)
        refresh()
    }

    // MARK: - Select-to-speak

    /// Called when the menu is about to open, so the item is never showing a permission
    /// state the user changed five minutes ago in System Settings.
    private func refreshSelectToSpeak() {
        menuBar?.setSelectToSpeak(active: SelectionReader.isTrusted)
    }

    /// The *only* place in this app that can raise a system permission dialog, and it is
    /// reachable only by the user clicking a menu item that says so. Nothing on the
    /// launch path, the hotkey path or the speak path calls it.
    private func enableSelectToSpeak() {
        AppLog.write("select-to-speak: user asked to enable it; prompting for Accessibility")
        SelectionReader.requestPermission()
        menuBar?.flash("Approve MoxSpeak in System Settings → Privacy", seconds: 5)

        // The grant lands whenever the user gets round to it, and macOS sends no
        // notification when it does. Nothing here polls: the next menu open re-checks,
        // and so does the next press of the speak shortcut.
    }

    // MARK: - Reset

    /// Erases the two things MoxSpeak leaves outside its own bundle — the preferences
    /// domain and the log — and puts the running app back to how it starts.
    ///
    /// `Reset` documents exactly what those two are, why they are the only two, and the
    /// one thing this cannot take back (the Accessibility approval, which belongs to
    /// macOS and not to us). Confirmed before anything is touched: it is irreversible,
    /// everything it removes was set by hand, and it sits one slip above "Quit MoxSpeak".
    private func resetEverything() {
        guard confirmReset() else {
            AppLog.write("reset: the user cancelled — nothing was touched")
            return
        }
        AppLog.write("reset: erasing preferences domain "
                     + "\(settings.domain ?? "(none — running without a bundle)") and this log")

        let wasPlaying = isPlaying
        teardownPlayback()
        if wasPlaying { nowPlaying.clear() }

        // Logging stops *before* the file is removed, and stays stopped for the rest of
        // this launch. `applicationWillTerminate` writes `terminate`, so a log deleted
        // while logging is still on is a log that reappears the moment the user quits —
        // leaving a file behind on a machine they have just been told is clean.
        AppLog.stopLogging()
        let log = Reset.eraseFile(at: AppLog.fileURL)
        let preferences = Reset.erasePreferences(in: settings.store, domain: settings.domain)
        let outcome = Reset.Outcome(preferencesCleared: preferences.cleared,
                                    leftoverKeys: preferences.leftoverKeys,
                                    logCleared: log.cleared,
                                    logProblem: log.problem)

        // First-launch state in memory as well as on disk. Clearing the plist while the
        // running app carried on at 1.25× in am_michael would be a reset the user cannot
        // see — and the next voice or speed change would write those same values back
        // into the domain they just emptied.
        rate = Settings.resolveRate(stored: nil)
        voice = Settings.resolveVoice(stored: nil, available: [])
        menuBar?.setSelectedRate(rate)
        // The shortcuts too: the domain has just been emptied, so a custom binding still
        // registered in this process would be a preference the user cannot see and cannot
        // account for — and the first rebinding after it would write into a domain they
        // asked to be left clean.
        restoreDefaultHotkeys()
        shortcuts?.apply(hotkeyBindings)
        lastError = nil
        engineWarning = nil

        if engineChoice != Settings.defaultEngine {
            // Persisting nothing: this is the engine a first launch picks anyway, and
            // writing it would put the first key straight back into an empty domain.
            // Reloads the voice list and warms the engine up as part of the switch.
            selectEngine(Settings.defaultEngine, persist: false)
        } else {
            menuBar?.setVoices([], selected: voice, note: "Loading voices…")
            beginEngine()
        }

        // After the engine switch, which sets its own idle note.
        idleNote = outcome.summary
        menuBar?.flash(outcome.isClean ? "Reset — back to first-launch settings"
                                       : "Reset was incomplete — see the menu",
                       seconds: 5)
        refresh()
    }

    /// The confirmation. One of the two windows this app ever puts on screen, the other
    /// being the shortcuts window.
    ///
    /// Two deliberate choices. "Cancel" is added *first*, which in an `NSAlert` makes it
    /// the rightmost, default, Return-activated button and leaves "Reset" beside it — the
    /// safe action is what a dialog dismissed on reflex performs, and Escape still cancels
    /// because the button is titled "Cancel". And `NSApp.activate()`, because an accessory
    /// app is not frontmost: without it the alert opens behind whatever the user was
    /// reading and looks like nothing happened.
    private func confirmReset() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Reset.confirmationTitle
        alert.informativeText = Reset.confirmationDetail
        alert.addButton(withTitle: Reset.cancelButton)
        alert.addButton(withTitle: Reset.confirmButton)

        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Playback

    /// Walks the chunks in order, waiting for each to render and handing it to the audio
    /// engine. Synthesis of later chunks continues in the background inside
    /// `SpeechSession` while earlier ones play, so this loop spends nearly all its time
    /// suspended.
    private func pump(text: String, engine: PlaybackEngine) async {
        let started = Date()
        // Read once, here: an engine change replaces `runtime` and cancels this task, but
        // holding the session locally means a half-torn-down utterance can never end up
        // asking the new engine about the old engine's chunks.
        let session = runtime.session
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
                    let elapsed = Date().timeIntervalSince(started)
                    health.record(timeToFirstSound: elapsed)
                    heardAnything = true
                    // Audible output is proof the engine loaded, whatever a warm-up said
                    // earlier. Leaving a stale warning up would be its own silent lie.
                    engineWarning = nil
                    // The menu rounds this to one decimal, which is right for a person
                    // glancing at it and useless for judging an engine against a
                    // half-second budget. The log keeps the milliseconds, so the number
                    // the plan is accountable to can be measured through the real app
                    // rather than through a harness that skips playback.
                    AppLog.write(String(format: "speak: first sound after %.3fs on the %@ engine",
                                        elapsed, engineChoice.logName))
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
            let runtime = self.runtime
            let generation = engineGeneration
            Task { [weak self] in
                let reachable = await runtime.probeReachable()
                guard let self, generation == self.engineGeneration else { return }
                if !reachable {
                    self.health.markUnreachable(
                        runtime.choice.unreachableReason(port: self.port))
                } else {
                    self.health.markReachable()
                }
                self.refresh()
            }
        }

        if failures.isEmpty {
            if chunkCount == 0 {
                idleNote = "Nothing to speak. That text had no readable words."
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
        let session = runtime.session
        Task { await session.cancelAll() }
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
            line = "Speaking at \(SpeedControl.format(rate)) in \(voice)"
        } else {
            icon = .idle
            line = idleNote
        }

        menuBar.setIcon(icon)
        let speakKey = hotkeyBindings[.speak]?.label ?? HotkeyAction.speak.defaultHotkey.label
        menuBar.setStatusLine(line,
                              hint: "Select some text, or copy it, then press \(speakKey).")
        menuBar.setEngineStatus(health.summary)
        menuBar.setWarning(warningLine)
        menuBar.setTransport(canSpeak: true,
                             isPlaying: isPlaying,
                             isPaused: engine?.isPaused ?? false)
    }

    /// Every standing problem at once, or nil when there are none. Two separate
    /// warnings must not hide each other — a broken hotkey and a broken engine are both
    /// things the user needs to know, and whichever was set second would otherwise win.
    private var warningLine: String? {
        let problems = [hotkeyWarning, engineWarning].compactMap { $0 }
        return problems.isEmpty ? nil : problems.joined(separator: " • ")
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
