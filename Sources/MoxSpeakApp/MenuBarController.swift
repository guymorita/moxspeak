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
        /// Erase the two things MoxSpeak leaves outside its own bundle. Destructive, and
        /// confirmed by the controller before anything is touched — see `Reset`.
        var reset: @MainActor () -> Void
        /// Fired every time the menu is about to appear. The controller uses it to
        /// re-read state that can change behind the app's back — Accessibility, which
        /// the user can grant or revoke in System Settings at any moment.
        var menuWillOpen: @MainActor () -> Void
        var quit: @MainActor () -> Void
    }

    /// The speeds the app can be in. `nonisolated` because this list is the definition
    /// of a valid speed, and `Settings` has to be able to check a restored one against it
    /// without touching the main actor.
    nonisolated static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    private let actions: Actions
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let statusLineItem = NSMenuItem()
    private let speakItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let stopItem = NSMenuItem()
    private let voiceItem = NSMenuItem()
    private let rateItem = NSMenuItem()
    private let engineChoiceItem = NSMenuItem()
    private let engineItem = NSMenuItem()
    private let warningItem = NSMenuItem()
    private let selectToSpeakItem = NSMenuItem()
    private let resetItem = NSMenuItem()

    /// Guards the transient flash message: a later flash must not be wiped by an earlier
    /// one's expiry.
    private var flashToken = 0

    init(actions: Actions) {
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

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
        // Carbon hotkey fires too, so ⌥⇧Space would toggle pause twice and appear to do
        // nothing. The title tells the user what the key is without wiring a second path
        // to the same action.
        configure(speakItem, title: "Speak Clipboard  (⌥⇧S)", action: #selector(speak))
        configure(pauseItem, title: "Pause  (⌥⇧Space)", action: #selector(togglePause))
        configure(stopItem, title: "Stop  (⌥⇧.)", action: #selector(stop))

        menu.addItem(.separator())

        voiceItem.title = "Voice"
        voiceItem.submenu = NSMenu()
        menu.addItem(voiceItem)

        rateItem.title = "Speed"
        rateItem.submenu = buildRateMenu()
        menu.addItem(rateItem)

        // Beside Voice and Speed, because it is the same kind of thing: a preference the
        // user owns, that persists, and that takes effect immediately. Filled in by
        // `setEngines` before the menu is ever shown.
        engineChoiceItem.title = "Engine"
        engineChoiceItem.submenu = NSMenu()
        menu.addItem(engineChoiceItem)

        menu.addItem(.separator())

        // Titled and enabled by `setSelectToSpeak`, which the controller calls before
        // the menu opens. It is never left in whatever state it was in ten minutes ago.
        selectToSpeakItem.target = self
        menu.addItem(selectToSpeakItem)
        setSelectToSpeak(active: false)

        menu.addItem(.separator())

        engineItem.title = "Voice engine: not measured yet"
        engineItem.isEnabled = false
        menu.addItem(engineItem)

        menu.addItem(.separator())

        // Beside Quit, because it belongs to the same moment: the user is finished with
        // MoxSpeak. No key equivalent — a destructive item is not something to arrive at
        // by muscle memory, and the ellipsis promises the confirmation that `Reset`
        // requires.
        resetItem.title = Reset.menuTitle
        resetItem.toolTip = Reset.menuDetail
        resetItem.action = #selector(reset)
        resetItem.target = self
        resetItem.isEnabled = true
        menu.addItem(resetItem)

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

    private func buildRateMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for rate in Self.rates {
            let item = NSMenuItem(title: Self.rateTitle(rate),
                                  action: #selector(selectRate(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = NSNumber(value: rate)
            item.state = (rate == 1.0) ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    static func rateTitle(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
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
    func setStatusLine(_ text: String) {
        statusLineItem.title = text
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
        pauseItem.title = (isPaused ? "Resume  (⌥⇧Space)" : "Pause  (⌥⇧Space)")
        pauseItem.isEnabled = isPlaying
        stopItem.isEnabled = isPlaying
    }

    /// Replaces the voice submenu.
    ///
    /// `note` is shown instead of the list when there is no list — and it says *why*
    /// there is no list. An empty "Voice" submenu would be the app failing silently at
    /// the exact moment the engine is unreachable.
    func setVoices(_ voices: [Voice], selected: String, note: String?) {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if voices.isEmpty {
            let item = NSMenuItem(title: note ?? "No voices available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        } else {
            for voice in voices {
                let item = NSMenuItem(title: voice.name,
                                      action: #selector(selectVoice(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.isEnabled = true
                item.representedObject = voice.id as NSString
                item.state = (voice.id == selected) ? .on : .off
                submenu.addItem(item)
            }
        }
        voiceItem.submenu = submenu
    }

    /// Replaces the engine submenu and names the current choice in the parent row.
    ///
    /// The parent says "Engine: Built in" rather than plain "Engine" so the answer is
    /// visible without opening a submenu. Which engine is speaking changes what the app
    /// depends on — a running server or nothing at all — and that is not something the
    /// user should have to go looking for.
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

    func setSelectedVoice(_ id: String) {
        for item in voiceItem.submenu?.items ?? [] {
            item.state = ((item.representedObject as? NSString) as String? == id) ? .on : .off
        }
    }

    /// Shows — and offers — the state of select-to-speak.
    ///
    /// Worded from the user's side. "Enable Select-to-Speak…" says what they get; the
    /// ellipsis says a system dialog is coming. Nothing here mentions Accessibility
    /// APIs, trusted processes or `AXUIElement`, because none of that is the user's
    /// problem. The ⌥⇧S item is retitled to match, so the menu never claims to read the
    /// clipboard while it is actually reading the selection, or the reverse.
    ///
    /// With select-to-speak on, the *item* still says clipboard while the *shortcut*
    /// says selection, and that is not a mistake: clicking a menu makes MoxSpeak the
    /// focused app, so by the time the click lands there is no other app's selection
    /// left to read. The item reads the clipboard because the clipboard is the only
    /// honest thing it can read.
    func setSelectToSpeak(active: Bool) {
        if active {
            selectToSpeakItem.title = "Select-to-Speak is on"
            selectToSpeakItem.toolTip = "⌥⇧S reads whatever is selected. "
                                      + "If nothing is selected, it says so."
            selectToSpeakItem.state = .on
            selectToSpeakItem.action = nil
            selectToSpeakItem.isEnabled = false
            speakItem.title = "Speak Clipboard  (⌥⇧S reads the selection)"
        } else {
            selectToSpeakItem.title = "Enable Select-to-Speak…"
            selectToSpeakItem.toolTip = "Let MoxSpeak read text you have selected, "
                                      + "instead of text you have copied. "
                                      + "macOS will ask you to approve this."
            selectToSpeakItem.state = .off
            selectToSpeakItem.action = #selector(enableSelectToSpeak)
            selectToSpeakItem.isEnabled = true
            speakItem.title = "Speak Clipboard  (⌥⇧S)"
        }
    }

    func setSelectedRate(_ rate: Float) {
        for item in rateItem.submenu?.items ?? [] {
            item.state = ((item.representedObject as? NSNumber)?.floatValue == rate) ? .on : .off
        }
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
    @objc private func togglePause() { actions.togglePause() }
    @objc private func stop() { actions.stop() }
    @objc private func reset() { actions.reset() }
    @objc private func quit() { actions.quit() }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSString) as String? else { return }
        actions.selectVoice(id)
    }

    @objc private func selectRate(_ sender: NSMenuItem) {
        guard let rate = (sender.representedObject as? NSNumber)?.floatValue else { return }
        actions.selectRate(rate)
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
    }
}
