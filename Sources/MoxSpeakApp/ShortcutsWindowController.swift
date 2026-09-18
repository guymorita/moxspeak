import AppKit

/// The one window MoxSpeak has: three recorder fields, and the reason a combination was
/// refused when one is.
///
/// ## Why a window rather than three more menu rows
///
/// Two reasons, and the first is not a matter of taste. A recorder has to receive raw
/// `keyDown` events, and an open `NSMenu` runs a modal event-tracking loop that consumes
/// them for type-select and key equivalents — a recorder inside a menu would not reliably
/// see the keys it exists to capture. Second, refusing a combination means saying *why*
/// in a sentence or two, and a menu row is a single line whose width is the menu's width;
/// the project has already been bitten once by a long row stretching the whole menu (see
/// `MenuBarController.setStatusLine`). Explaining the macOS 15 restriction in the menu
/// would either be unreadably terse or make the menu three times too wide.
///
/// So the menu gains one row — "Keyboard Shortcuts…", a plain `NSMenuItem` beside Voice,
/// Speed and Engine, so AppKit gives it the same text inset as its neighbours and there is
/// nothing to measure — and everything else lives here.
///
/// ## What this window is responsible for, and what it is not
///
/// It owns the explaining. It does not own the deciding: `rebind` goes back out to
/// `AppController`, which validates, registers, persists and answers with nil or with a
/// sentence. A refusal leaves the field showing the binding that is actually in force,
/// never the one that was rejected — the window must not be able to imply a shortcut is
/// set when it is not.
@MainActor
final class ShortcutsWindowController: NSObject, NSWindowDelegate {

    struct Actions {
        /// What is registered right now. Asked for rather than remembered, because a
        /// binding can change without this window: a migration at launch, or a future
        /// caller. A window that cached it would eventually show a shortcut that is not
        /// the one in force, which is the exact failure this feature exists to end.
        var current: @MainActor () -> [HotkeyAction: Hotkey]
        /// Try to put a combination in place. Nil means it took; a string is what to tell
        /// the user, and the field goes back to what is actually registered.
        var rebind: @MainActor (HotkeyAction, Hotkey) -> String?
        /// Put all three back to the shipped defaults, and answer with what they now are.
        var restoreDefaults: @MainActor () -> [HotkeyAction: Hotkey]
    }

    private let actions: Actions
    private var window: NSWindow?
    private var recorders: [HotkeyAction: ShortcutRecorderView] = [:]
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// Guards the delayed "put the field back" after a refusal, so a second refusal's
    /// revert cannot be undone by the first one's timer.
    private var revertToken = 0

    init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    /// Brings the window up, building it the first time.
    func show() {
        if window == nil { build() }
        apply(actions.current())
        clearMessage()

        // An `.accessory` app is not activated by clicking its status item, so without
        // this the window would appear behind whatever the user was working in and take a
        // second click to reach — and the recorder needs the window to be *key* before it
        // can capture anything at all.
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        AppLog.write("shortcuts: window opened")
    }

    /// Pushes registered combinations into the fields, from a rebinding or a restore.
    func apply(_ hotkeys: [HotkeyAction: Hotkey]) {
        for (action, hotkey) in hotkeys { recorders[action]?.setHotkey(hotkey) }
    }

    // MARK: - Building

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        stack.addArrangedSubview(paragraph(
            "Click a field and press the combination you want."))

        for action in HotkeyAction.allCases {
            let recorder = ShortcutRecorderView(hotkey: action.defaultHotkey)
            recorder.onCapture = { [weak self] hotkey in self?.capture(hotkey, for: action) }
            recorders[action] = recorder

            let name = NSTextField(labelWithString: action.title)
            name.alignment = .right
            name.toolTip = action.detail
            name.translatesAutoresizingMaskIntoConstraints = false
            name.widthAnchor.constraint(equalToConstant: 110).isActive = true

            let row = NSStackView(views: [name, recorder])
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            stack.addArrangedSubview(row)
        }

        // Permanently visible rather than shown only on a failure. `RegisterEventHotKey`
        // returns `noErr` for a combination another app already holds, so MoxSpeak cannot
        // detect that case and cannot warn about it after the fact — the only honest place
        // to say so is up front, beside the thing it applies to.
        stack.addArrangedSubview(paragraph(
            "A shortcut must include Control or Command. macOS ignores global shortcuts "
            + "held with only Option and Shift.\n\n"
            + "If a shortcut does nothing, another app probably has it — macOS does not "
            + "tell MoxSpeak when that happens, so try a different combination.",
            secondary: true))

        messageLabel.textColor = .systemRed
        messageLabel.isSelectable = false
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.preferredMaxLayoutWidth = Self.contentWidth - 40
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth - 40).isActive = true
        stack.addArrangedSubview(messageLabel)

        let restore = NSButton(title: "Use Defaults",
                               target: self,
                               action: #selector(restoreDefaults))
        restore.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [restore, spacer, done])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: Self.contentWidth - 40).isActive = true
        stack.addArrangedSubview(buttons)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 320),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "MoxSpeak Shortcuts"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = stack
        self.window = window
        resizeToFit()
    }

    /// Grows and shrinks the window around its content, anchored at the top edge.
    ///
    /// Needed because the one variable-height thing in this window is the reason a
    /// combination was refused, and that is four lines when the macOS 15 restriction is
    /// being explained and none at all the rest of the time. A window sized once, when the
    /// message was empty, pushes its own buttons off the bottom the first time it has
    /// something to say — which is precisely the moment the user needs the window to be
    /// legible. Reserving four blank lines for a message that is usually absent would be
    /// the other half of the same mistake.
    ///
    /// Anchored at the top because that is where the fields are: growing downwards leaves
    /// everything the user is looking at exactly where it was.
    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        let outer = window.frameRect(forContentRect: NSRect(x: 0, y: 0,
                                                            width: Self.contentWidth,
                                                            height: height))
        var frame = window.frame
        let top = frame.maxY
        frame.size = NSSize(width: outer.width, height: outer.height)
        frame.origin.y = top - outer.height
        window.setFrame(frame, display: true)
    }

    private static let contentWidth: CGFloat = 420

    private func paragraph(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = false
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        if secondary { label.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        label.preferredMaxLayoutWidth = Self.contentWidth - 40
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.contentWidth - 40).isActive = true
        return label
    }

    // MARK: - Acting on what was recorded

    /// The combination the user just pressed, on its way to being accepted or explained.
    ///
    /// Validation happens here — before `AppController` is asked for anything — because
    /// this is the one place that can say why in full and point at the field it is about.
    /// `AppController` checks again on the way to Carbon; duplicated on purpose, since the
    /// rule has to hold for callers that never come through this window (a stored binding
    /// restored at launch, say).
    private func capture(_ hotkey: Hotkey, for action: HotkeyAction) {
        if let reason = hotkey.rejection {
            recorders[action]?.setHotkey(hotkey)
            show(message: "\(hotkey.label) will not work. \(reason.explanation)")
            AppLog.write("shortcuts: refused \(hotkey.label) for \(action.rawValue) — \(reason)")
            revertAfterAMoment(action)
            return
        }

        if let problem = actions.rebind(action, hotkey) {
            recorders[action]?.setHotkey(hotkey)
            show(message: problem)
            revertAfterAMoment(action)
            return
        }
        clearMessage()
    }

    /// Shows the refused combination in red for a beat, then puts the field back to what
    /// is really registered. The pause is the whole point: a field that snapped back
    /// instantly would look as though the keypress had not registered, and the user would
    /// press harder rather than read the reason.
    private func revertAfterAMoment(_ action: HotkeyAction) {
        revertToken += 1
        let token = revertToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, self.revertToken == token else { return }
            let live = self.actions.current()[action] ?? action.defaultHotkey
            self.recorders[action]?.setHotkey(live)
        }
    }

    private func show(message: String) {
        messageLabel.stringValue = message
        resizeToFit()
    }

    private func clearMessage() {
        messageLabel.stringValue = ""
        resizeToFit()
    }

    @objc private func restoreDefaults() {
        apply(actions.restoreDefaults())
        clearMessage()
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Whatever was half-recorded is abandoned; the next open starts clean.
        window?.makeFirstResponder(nil)
        clearMessage()
    }
}
