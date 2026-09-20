import AppKit
import MoxSpeakCore

/// The status item, its icon, and its menu. Owns no speech state — everything it shows
/// is pushed in by `AppController`, and everything the user clicks goes back out through
/// `Actions`.
///
/// The menu is built once and mutated in place rather than rebuilt on each change. An
/// `NSMenu` replaced while it is open closes under the user's cursor, and this menu's
/// contents change exactly while it is open (a status line ticking over during playback).
@MainActor
final class MenuBarController: NSObject {

    /// What the icon is saying from across the room.
    enum IconState {
        case idle
        case speaking
        case paused
        case error
    }

    /// Everything the menu can ask for. Closures rather than a delegate protocol: there
    /// is exactly one implementer and the call sites read better inline.
    struct Actions {
        var speak: @MainActor () -> Void
        var togglePause: @MainActor () -> Void
        var stop: @MainActor () -> Void
        var selectVoice: @MainActor (String) -> Void
        var selectRate: @MainActor (Float) -> Void
        var selectEngine: @MainActor (EngineChoice) -> Void
        var enableSelectToSpeak: @MainActor () -> Void
        /// Open the shortcuts window. A window rather than a menu row because a recorder
        /// has to receive raw key events, and an open `NSMenu` runs its own event-tracking
        /// loop that consumes them — see `ShortcutsWindowController`.
        var openShortcuts: @MainActor () -> Void
        /// Erase the two things MoxSpeak leaves outside its own bundle. Destructive, and
        /// confirmed by the controller before anything is touched — see `Reset`.
        var reset: @MainActor () -> Void
        /// Open the page where a newer version can be downloaded.
        var openDownloadPage: @MainActor () -> Void
        /// Whether MoxSpeak is set to open at login right now.
        var isLaunchAtLoginEnabled: @MainActor () -> Bool
        /// Turn the login item on or off.
        var setLaunchAtLoginEnabled: @MainActor (Bool) -> Void
        /// Whether anonymous usage reporting is on right now.
        var isTelemetryEnabled: @MainActor () -> Bool
        /// Turn anonymous usage reporting on or off.
        var setTelemetryEnabled: @MainActor (Bool) -> Void
        /// Open the page describing exactly what is and is not collected.
        var openPrivacy: @MainActor () -> Void
        /// Fired every time the menu is about to appear. The controller uses it to
        /// re-read state that can change behind the app's back — Accessibility, which
        /// the user can grant or revoke in System Settings at any moment.
        var menuWillOpen: @MainActor () -> Void
        var quit: @MainActor () -> Void
    }

    private let actions: Actions
    private let statusItem: NSStatusItem

    /// Where the gemstone actually is on screen, so the welcome window can be anchored
    /// under it — or nil when that cannot be answered honestly.
    ///
    /// The nil cases are the point. A status item's button has a window from the moment
    /// it is created, but AppKit has not yet placed it in the menu bar, and converting
    /// through an unplaced window returns a plausible-looking rectangle that is simply
    /// wrong: measured at launch it reported `(0, -33.5, 34, 31)` — off the bottom-left
    /// of a screen whose menu bar is at the top — and a caller that trusted it put the
    /// welcome window in the corner of the screen furthest from the icon it was pointing
    /// at. So the frame is checked against the one thing that must be true of a menu bar
    /// item: it sits in the strip above the visible frame. Anything else is nil, and the
    /// caller falls back to the top-right corner, which is where the menu bar is anyway.
    var statusItemFrame: CGRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = window.screen ?? NSScreen.main else { return nil }
        // The menu bar occupies the gap between the screen's full frame and its visible
        // frame. An item genuinely in the menu bar has its bottom edge at or above the
        // top of the visible area, and lies within the screen horizontally.
        guard frame.minY >= screen.visibleFrame.maxY - 1,
              frame.maxY <= screen.frame.maxY + 1,
              frame.minX >= screen.frame.minX, frame.maxX <= screen.frame.maxX
        else { return nil }
        return frame
    }
    private let menu = NSMenu()

    private let statusLineItem = NSMenuItem()
    private let speakItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let stopItem = NSMenuItem()
    private let voiceItem = NSMenuItem()
    private let rateItem = NSMenuItem()
    private let speedControlView = SpeedControlView()
    private let engineChoiceItem = NSMenuItem()
    private let engineItem = NSMenuItem()
    private let warningItem = NSMenuItem()
    private let shortcutsItem = NSMenuItem()
    private let selectToSpeakItem = NSMenuItem()
    private let resetItem = NSMenuItem()
    private let telemetryItem = NSMenuItem()
    private let updateItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let versionItem = NSMenuItem()

    /// Guards the transient flash message: a later flash must not be wiped by an earlier
    /// one's expiry.
    private var flashToken = 0

    /// The last voice list pushed in, kept so `setSelectedVoice` can rebuild the submenu
    /// around a new choice without asking the engine for the list a second time.
    private var lastVoices: [Voice] = []
    private var lastNote: String?

    /// How each shortcut is currently written, and the two pieces of state that decide
    /// what the rows around them say.
    ///
    /// Held rather than recomputed from the controller each time because three separate
    /// callers retitle these rows — `setHotkeys`, `setTransport` and `setSelectToSpeak` —
    /// and each of them knows only its own third of the sentence. Before rebinding
    /// existed the shortcut was a literal in three string constants; now that it can
    /// change under a running menu, one of those three callers would otherwise put a
    /// stale combination back.
    private var hotkeyLabels: [HotkeyAction: String] = HotkeyAction.allCases
        .reduce(into: [:]) { $0[$1] = $1.defaultHotkey.label }
    private var selectToSpeakActive = false
    private var transportIsPaused = false

    init(actions: Actions) {
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        speedControlView.onChange = { [weak self] rate in self?.actions.selectRate(rate) }
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        setIcon(.idle)

        AppLog.write("menu bar: status item created "
                     + "(button=\(statusItem.button != nil), "
                     + "icon=\(statusItem.button?.image != nil), "
                     + "items=\(menu.items.count))")
    }

    // MARK: - Building

    private func buildMenu() {
        menu.autoenablesItems = false

        statusLineItem.title = "Ready"
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        warningItem.isEnabled = false
        warningItem.isHidden = true
        menu.addItem(warningItem)

        menu.addItem(.separator())

        // Shortcuts are written into the titles rather than set as `keyEquivalent`.
        // A key equivalent on a status menu fires while the menu is open — and the global
        // Carbon hotkey fires too, so ⌃⌥D would toggle pause twice and appear to do
        // nothing. The title tells the user what the key is without wiring a second path
        // to the same action.
        configure(speakItem, title: "Speak Clipboard", action: #selector(speak))
        configure(pauseItem, title: "Pause", action: #selector(togglePause))
        configure(stopItem, title: "Stop", action: #selector(stop))
        applyHotkeyTitles()

        menu.addItem(.separator())

        voiceItem.title = "Voice"
        voiceItem.submenu = NSMenu()
        menu.addItem(voiceItem)

        // A custom view rather than a submenu: dragging is the whole appeal over the old
        // five fixed presets, and a slider buried one level down would cost a click just
        // to reach the thing the owner asked for. `isEnabled` stays true so AppKit routes
        // mouse events into the view instead of treating the row as inert.
        rateItem.title = "Speed"
        rateItem.view = speedControlView
        rateItem.isEnabled = true
        menu.addItem(rateItem)

        // Beside the other three preferences, and a plain `NSMenuItem` like them: no
        // custom view, so AppKit supplies the same text inset it gives "Voice" and
        // "Engine" and this row needs no measuring to line up. The ellipsis says a window
        // is coming.
        shortcutsItem.title = "Keyboard Shortcuts…"
        shortcutsItem.toolTip = "Change the keys that speak, pause and stop."
        shortcutsItem.action = #selector(openShortcuts)
        shortcutsItem.target = self
        shortcutsItem.isEnabled = true
        menu.addItem(shortcutsItem)

        menu.addItem(.separator())

        // Titled and enabled by `setSelectToSpeak`, which the controller calls before
        // the menu opens. It is never left in whatever state it was in ten minutes ago.
        selectToSpeakItem.target = self
        menu.addItem(selectToSpeakItem)
        setSelectToSpeak(active: false)

        // Hidden unless there is actually a newer release. An update row that is always
        // present, greyed out and saying "up to date", is a permanent piece of furniture
        // earning nothing; one that appears only when it has news is worth looking at.
        updateItem.action = #selector(openDownloadPage)
        updateItem.target = self
        updateItem.isEnabled = true
        updateItem.isHidden = true
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // Everything here is real, reachable and rarely wanted, which is exactly what a
        // submenu is for. The telemetry switch in particular is deliberately not a
        // top-level row: presenting it as a headline choice would tell every user that
        // this is a decision they need to make before using a text-to-speech app, which
        // overstates it. It is disclosed on the welcome window, it is one click from
        // here, and Privacy… says precisely what is collected.
        //
        // Reset moves in here too. It is destructive and almost never wanted, and it was
        // sitting next to Quit where a slip costs somebody their settings.
        let advanced = NSMenu()
        advanced.autoenablesItems = false

        // A diagnostic, not a preference, and phrased for whoever is helping rather than
        // for the person using the app. It was on the top level reading "Voice engine:
        // not measured yet", which to a new user looks like a warning about something
        // they have done wrong.
        engineItem.isEnabled = false
        advanced.addItem(engineItem)
        advanced.addItem(.separator())

        // Offered on the welcome window too, but that is shown once and never again.
        // Somebody who unticked it there, or who changes their mind after a reboot, needs
        // a way back, and this is the only place a setting like it can live.
        loginItem.title = "Open MoxSpeak at login"
        loginItem.toolTip = "Start MoxSpeak automatically when you log in."
        loginItem.action = #selector(toggleLaunchAtLogin)
        loginItem.target = self
        loginItem.isEnabled = true
        advanced.addItem(loginItem)

        telemetryItem.title = "Send anonymous usage stats"
        telemetryItem.toolTip = "Crash reports and a short list of usage events. No text "
                              + "you select or copy is ever included."
        telemetryItem.action = #selector(toggleTelemetry)
        telemetryItem.target = self
        telemetryItem.isEnabled = true
        advanced.addItem(telemetryItem)
        refreshAdvancedState()

        let privacy = NSMenuItem(title: "Privacy…", action: #selector(openPrivacy),
                                 keyEquivalent: "")
        privacy.toolTip = "Exactly what is and is not sent."
        privacy.target = self
        privacy.isEnabled = true
        advanced.addItem(privacy)

        advanced.addItem(.separator())

        // No key equivalent — a destructive item is not something to arrive at by muscle
        // memory, and the ellipsis promises the confirmation that `Reset` requires.
        resetItem.title = Reset.menuTitle
        resetItem.toolTip = Reset.menuDetail
        resetItem.action = #selector(reset)
        resetItem.target = self
        resetItem.isEnabled = true
        advanced.addItem(resetItem)

        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.submenu = advanced
        advancedItem.isEnabled = true
        menu.addItem(advancedItem)

        // Quiet and informational, in the style of `engineItem` above: a plain
        // `NSMenuItem`, disabled so it reads as text rather than a control, with nothing
        // to click. Right by Quit because that is the last thing on the menu, and a build
        // identity is the kind of thing you go looking for at the bottom of something,
        // not the top. Computed once at menu build time — unlike the engine status, the
        // running build does not change out from under a live process.
        versionItem.title = AppVersion.read().display
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quitItem = NSMenuItem(title: "Quit MoxSpeak", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func configure(_ item: NSMenuItem, title: String, action: Selector) {
        item.title = title
        item.action = action
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    // MARK: - State the controller pushes in

    func setIcon(_ state: IconState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let description: String
        switch state {
        case .idle:
            symbol = "diamond"
            description = "MoxSpeak: idle"
        case .speaking:
            symbol = "diamond.fill"
            description = "MoxSpeak: speaking"
        case .paused:
            symbol = "diamond.lefthalf.filled"
            description = "MoxSpeak: paused"
        case .error:
            symbol = "exclamationmark.triangle"
            description = "MoxSpeak: something went wrong"
        }

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) {
            image.isTemplate = true
            button.image = image
        } else {
            // No SF Symbol is still better than an invisible status item.
            button.image = nil
            button.title = "SE"
        }
        button.toolTip = description
    }

    /// The one-line summary at the top of the menu.
    ///
    /// Kept short on purpose. This row is a plain `NSMenuItem`, so whatever it says
    /// sets the menu's width — a full sentence here stretched the whole menu to about
    /// three times the width of its own controls. Guidance the user might want but
    /// does not need to re-read every time goes in `hint`, shown on hover instead.
    func setStatusLine(_ text: String, hint: String? = nil) {
        statusLineItem.title = text
        statusLineItem.toolTip = hint
    }

    func setEngineStatus(_ text: String) {
        engineItem.title = text
    }

    /// A standing problem that is not about the current utterance — a hotkey another app
    /// owns, for instance. Hidden entirely when there is nothing to say, so the menu does
    /// not carry a permanently empty row.
    func setWarning(_ text: String?) {
        if let text {
            warningItem.title = "⚠︎ \(text)"
            warningItem.isHidden = false
        } else {
            warningItem.isHidden = true
        }
    }

    /// Enables and titles the transport items for the current state.
    func setTransport(canSpeak: Bool, isPlaying: Bool, isPaused: Bool) {
        speakItem.isEnabled = canSpeak
        transportIsPaused = isPaused
        applyHotkeyTitles()
        pauseItem.isEnabled = isPlaying
        stopItem.isEnabled = isPlaying
    }

    /// The combinations currently registered, pushed in at launch and again after every
    /// rebinding. The menu is the only place most users will ever read them, so it has to
    /// be the truth rather than what shipped.
    func setHotkeys(_ hotkeys: [HotkeyAction: Hotkey]) {
        for (action, hotkey) in hotkeys { hotkeyLabels[action] = hotkey.label }
        applyHotkeyTitles()
    }

    private func label(_ action: HotkeyAction) -> String {
        hotkeyLabels[action] ?? action.defaultHotkey.label
    }

    /// Writes the current combinations into every row that mentions one. One function, so
    /// the three rows cannot disagree about which shortcut does what.
    private func applyHotkeyTitles() {
        speakItem.title = selectToSpeakActive
            ? "Speak Clipboard  (\(label(.speak)) reads the selection)"
            : "Speak Clipboard  (\(label(.speak)))"
        pauseItem.title = (transportIsPaused ? "Resume" : "Pause") + "  (\(label(.pause)))"
        stopItem.title = "Stop  (\(label(.stop)))"
        if selectToSpeakActive {
            selectToSpeakItem.toolTip = "\(label(.speak)) reads whatever is selected. "
                                      + "If nothing is selected, it says so."
        }
    }

    /// Replaces the voice submenu.
    ///
    /// The list arrives from the engine as bare identifiers — `af_bella`, `am_michael` —
    /// and is handed to `VoiceCatalog` to become names, accents and a shape. Everything
    /// about *what the menu says and how it is arranged* lives there, where it can be
    /// tested; what is left here is turning four node kinds into `NSMenuItem`s.
    ///
    /// Every row is a plain `NSMenuItem`. That is a deliberate constraint rather than a
    /// coincidence: a plain item gets its text inset from AppKit and lines up with
    /// "Voice" and "Speak Clipboard" for free, where a custom view has to measure and
    /// reproduce that inset by hand (see the note at the top of `SpeedControlView` about
    /// how that went the first time).
    ///
    /// `note` is shown instead of the list when there is no list — and it says *why*
    /// there is no list. An empty "Voice" submenu would be the app failing silently at
    /// the exact moment the engine is unreachable.
    func setVoices(_ voices: [Voice], selected: String, note: String?) {
        lastVoices = voices
        lastNote = note

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if voices.isEmpty {
            let item = NSMenuItem(title: note ?? "No voices available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        } else {
            let nodes = VoiceCatalog.menu(available: voices.map(\.id), current: selected)
            add(nodes, to: submenu, selected: selected)
        }
        voiceItem.submenu = submenu
        // Named on the parent row, exactly as the engine is. "Which voice am I on" is a
        // question the menu should answer before it is opened, not after a submenu is
        // hunted through for a checkmark.
        voiceItem.title = "Voice: \(VoiceCatalog.shortName(for: selected))"
    }

    private func add(_ nodes: [VoiceCatalog.Node], to menu: NSMenu, selected: String) {
        for node in nodes {
            switch node {
            case .separator:
                menu.addItem(.separator())

            case .header(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)

            case .voice(let id, let title, let tooltip):
                let item = NSMenuItem(title: title,
                                      action: #selector(selectVoice(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.isEnabled = true
                item.toolTip = tooltip
                item.representedObject = id as NSString
                item.state = (id == selected) ? .on : .off
                menu.addItem(item)

            case .group(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = true
                let child = NSMenu()
                child.autoenablesItems = false
                add(children, to: child, selected: selected)
                item.submenu = child
                menu.addItem(item)
            }
        }
    }

    /// Replaces the engine submenu and names the current choice in the parent row.
    ///
    /// **Not in the menu.** The picker is built and kept current, but nothing adds
    /// `engineChoiceItem` to the menu any more.
    ///
    /// MoxSpeak ships one engine. A picker with one real option is a promise that has not
    /// been made, and the other option is worse than useless to the people this is for:
    /// choosing "Kokoro server" points the app at an HTTP server that is not running, so
    /// the setting's wrong answer is silent failure. "Built in" communicates nothing to
    /// somebody who does not know there is an alternative — the row's whole information
    /// content was "there is a concept here you should worry about", which is false.
    ///
    /// The seam stays. `SpeechProvider`, `OpenAICompatibleProvider` and this picker are
    /// what make a second engine cheap when there is a second engine; they simply stop
    /// being a user-facing concept until then. `defaults write com.moxspeak.menubar
    /// engine http` still selects it, which is the right amount of support for the one
    /// person in a thousand pointing this at their own server.
    func setEngines(_ choices: [EngineChoice], selected: EngineChoice, port: Int) {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for choice in choices {
            let item = NSMenuItem(title: choice.menuTitle(port: port),
                                  action: #selector(selectEngine(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.toolTip = choice.menuDetail(port: port)
            item.representedObject = choice.rawValue as NSString
            item.state = (choice == selected) ? .on : .off
            submenu.addItem(item)
        }
        engineChoiceItem.submenu = submenu
        engineChoiceItem.title = "Engine: \(selected.shortName)"
    }

    func setSelectedEngine(_ choice: EngineChoice) {
        for item in engineChoiceItem.submenu?.items ?? [] {
            item.state = ((item.representedObject as? NSString) as String? == choice.rawValue)
                ? .on : .off
        }
        engineChoiceItem.title = "Engine: \(choice.shortName)"
    }

    /// Moves the tick — and, when there is a list, rebuilds the submenu around the new
    /// choice.
    ///
    /// Rebuilding rather than flipping checkmarks in place, because *which rows exist*
    /// depends on the selection and not only on which one is ticked: a voice outside the
    /// featured set is pinned to the top of the menu under "Current", and that pin has to
    /// move with the user. Safe to do here — choosing a menu item dismisses the menu, so
    /// nothing is being replaced under the cursor.
    func setSelectedVoice(_ id: String) {
        guard lastVoices.isEmpty else {
            setVoices(lastVoices, selected: id, note: lastNote)
            return
        }
        voiceItem.title = "Voice: \(VoiceCatalog.shortName(for: id))"
    }

    /// Shows — and offers — the state of select-to-speak.
    ///
    /// Worded from the user's side. "Enable Select-to-Speak…" says what they get; the
    /// ellipsis says a system dialog is coming. Nothing here mentions Accessibility
    /// APIs, trusted processes or `AXUIElement`, because none of that is the user's
    /// problem. The speak item is retitled to match, so the menu never claims to read the
    /// clipboard while it is actually reading the selection, or the reverse.
    ///
    /// With select-to-speak on, the *item* still says clipboard while the *shortcut*
    /// says selection, and that is not a mistake: clicking a menu makes MoxSpeak the
    /// focused app, so by the time the click lands there is no other app's selection
    /// left to read. The item reads the clipboard because the clipboard is the only
    /// honest thing it can read.
    func setSelectToSpeak(active: Bool) {
        selectToSpeakActive = active
        if active {
            selectToSpeakItem.title = "Select-to-Speak is on"
            selectToSpeakItem.state = .on
            selectToSpeakItem.action = nil
            selectToSpeakItem.isEnabled = false
        } else {
            selectToSpeakItem.title = "Enable Select-to-Speak…"
            selectToSpeakItem.toolTip = "Let MoxSpeak read text you have selected, "
                                      + "instead of text you have copied. "
                                      + "macOS will ask you to approve this."
            selectToSpeakItem.state = .off
            selectToSpeakItem.action = #selector(enableSelectToSpeak)
            selectToSpeakItem.isEnabled = true
        }
        applyHotkeyTitles()
    }

    /// Pushes a rate into the slider and the exact-value field — a launch restore, a
    /// reset, or the menu being about to reopen after something else changed it.
    func setSelectedRate(_ rate: Float) {
        speedControlView.setSpeed(rate)
    }

    /// A brief, non-modal acknowledgement shown beside the icon, then removed.
    ///
    /// This is what an empty clipboard gets. A modal alert for "there was nothing to
    /// read" would be wildly out of proportion for a hotkey pressed by accident, and
    /// doing nothing at all would leave the user unable to tell the app from a dead one.
    func flash(_ text: String, seconds: TimeInterval = 2.0) {
        guard let button = statusItem.button else { return }
        flashToken += 1
        let token = flashToken
        button.title = " \(text)"

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.flashToken == token else { return }
            self.statusItem.button?.title = ""
        }
    }

    // MARK: - Menu actions

    @objc private func speak() { actions.speak() }
    @objc private func enableSelectToSpeak() { actions.enableSelectToSpeak() }
    @objc private func openShortcuts() { actions.openShortcuts() }
    @objc private func togglePause() { actions.togglePause() }
    @objc private func stop() { actions.stop() }
    @objc private func reset() { actions.reset() }

    @objc private func toggleTelemetry() {
        actions.setTelemetryEnabled(!actions.isTelemetryEnabled())
        refreshAdvancedState()
    }

    @objc private func toggleLaunchAtLogin() {
        actions.setLaunchAtLoginEnabled(!actions.isLaunchAtLoginEnabled())
        // Read back rather than assume: macOS can refuse a login item when the user has
        // disabled it in System Settings, and a tick that showed what we asked for rather
        // than what happened would be a lie the user acts on.
        refreshAdvancedState()
    }

    @objc private func openPrivacy() { actions.openPrivacy() }

    @objc private func openDownloadPage() { actions.openDownloadPage() }

    /// Shows or hides the update row. Nil hides it, which is also how it starts, so a
    /// failed or skipped check leaves the menu exactly as it was.
    func setUpdateAvailable(_ version: String?) {
        guard let version else {
            updateItem.isHidden = true
            return
        }
        updateItem.title = "Update to \(version)"
        updateItem.toolTip = "Opens the download page. MoxSpeak does not update itself."
        updateItem.isHidden = false
    }

    /// Both ticks reflect what is actually in force, re-read each time the menu opens
    /// rather than remembered, so neither can drift from the setting it claims to show.
    /// The login item in particular can be switched off in System Settings behind the
    /// app's back.
    private func refreshAdvancedState() {
        telemetryItem.state = actions.isTelemetryEnabled() ? .on : .off
        loginItem.state = actions.isLaunchAtLoginEnabled() ? .on : .off
        loginItem.isHidden = !LaunchAtLogin.isAvailable
    }
    @objc private func quit() { actions.quit() }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSString) as String? else { return }
        actions.selectVoice(id)
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = (sender.representedObject as? NSString) as String?,
              let choice = EngineChoice(rawValue: raw) else { return }
        actions.selectEngine(choice)
    }
}

// MARK: - Menu delegate

extension MenuBarController: NSMenuDelegate {

    /// Permission state is not ours to cache — the user can change it in System Settings
    /// while this menu sits idle in the menu bar. Re-asking at the moment the menu opens
    /// is cheap and is the only way the item can be right.
    func menuWillOpen(_ menu: NSMenu) {
        actions.menuWillOpen()
        // Re-read rather than remember. A tick has to show what is actually in force:
        // without this the items render unchecked forever and read as buttons rather
        // than as the switches they are.
        refreshAdvancedState()
    }
}
