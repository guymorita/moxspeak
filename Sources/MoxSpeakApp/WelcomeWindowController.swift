import AppKit

/// The window somebody sees once, the first time they open MoxSpeak.
///
/// ## Why this exists at all
///
/// MoxSpeak is `LSUIElement`: no Dock icon, no app switcher entry, no window. Before this
/// existed, installing it and double-clicking produced *nothing a person could see* except
/// a small gemstone appearing at the top of the screen, which nobody is looking at. They
/// did not know there was a shortcut, did not know about Accessibility, and had no reason
/// to believe the app had started. That is not a rough edge; it is the product failing to
/// begin, and it is the single most likely reason a download becomes a deletion.
///
/// ## What it is allowed to do
///
/// Three facts and one button. It is not a tour, not a wizard, and not a settings screen —
/// everything here is either something they cannot discover on their own, or something
/// that stops working later if it is not done now:
///
/// - **Where the app is.** Kills the "did it even install" question before it is asked.
///   The window is positioned directly under the status item so the answer is visible
///   rather than described.
/// - **The shortcut.** It is the entire product, and it is otherwise invisible.
/// - **Accessibility.** The only thing standing between "reads your clipboard" and
///   "reads what you selected", which is what it says on the box. One button, because
///   two buttons means neither gets read.
/// - **Open at login.** Without it, a reboot silently removes MoxSpeak from somebody's
///   life and they never think about it again. Checked by default; unchecking is one
///   click and reversible from the menu.
///
/// The telemetry sentence is the smallest text on the window and has no control beside
/// it. Consent here is an honest disclosure, not a negotiation — the switch lives under
/// Advanced, where it reads as plumbing rather than as a decision somebody has to make
/// before they have even heard the app speak.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {

    struct Actions {
        /// Raises the system's Accessibility prompt. Returns whether trust was already
        /// granted, so an already-approved reinstall does not ask again.
        var requestAccessibility: @MainActor () -> Bool
        /// Whether Accessibility is granted right now.
        var isAccessibilityTrusted: @MainActor () -> Bool
        /// Called once, when the window is dismissed for good.
        var finish: @MainActor (_ launchAtLogin: Bool) -> Void
    }

    private let actions: Actions
    private let shortcutLabel: String
    private let shortcutWords: String
    private var window: NSWindow?
    private var accessibilityButton: NSButton?
    private var accessibilityNote: NSTextField?
    private var statusIcon: NSImageView?
    private var statusText: NSTextField?
    private var startButton: NSButton?
    private var loginCheckbox: NSButton?
    /// Invalidated in `windowWillClose`, which is the only way this window ends. Not in
    /// `deinit`: a nonisolated deinit cannot touch a main-actor, non-Sendable Timer under
    /// strict concurrency, and the controller outlives the window anyway.
    private var pollTimer: Timer?

    init(shortcutLabel: String, shortcutWords: String, actions: Actions) {
        self.shortcutLabel = shortcutLabel
        self.shortcutWords = shortcutWords
        self.actions = actions
        super.init()
    }

    // MARK: - Showing

    /// Brings the window up beneath `statusItemFrame` — the status item's frame in screen
    /// coordinates — so the arrow points at the real icon rather than at where the icon
    /// usually is. Nil falls back to the top-right of the main screen, which is where the
    /// status bar is anyway.
    func show(under statusItemFrame: CGRect?) {
        if window == nil { build() }
        guard let window else { return }
        refreshAccessibilityState()
        position(window, under: statusItemFrame)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    private func position(_ window: NSWindow, under frame: CGRect?) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        // Anchored to the status item's centre, then pulled back inside the screen so a
        // gemstone near the right edge — or hidden behind a notch — cannot push the
        // window off the display.
        let anchorX = frame.map { $0.midX } ?? (visible.maxX - 40)
        let x = min(max(visible.minX + 12, anchorX - size.width / 2),
                    visible.maxX - size.width - 12)
        let top = frame.map { $0.minY } ?? visible.maxY
        window.setFrameOrigin(CGPoint(x: x, y: top - size.height - 10))
    }

    // MARK: - Building

    private func build() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 0))

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let title = label("MoxSpeak", font: .systemFont(ofSize: 22, weight: .semibold))
        title.alignment = .center

        let hint = MenuBarHintView()

        let whereItIs = label(
            "Look for this icon at the top of your screen. MoxSpeak has no window and "
            + "no Dock icon. That is normal.",
            font: .systemFont(ofSize: 13), secondary: true)
        whereItIs.alignment = .center

        let howTo = label("Select any text, anywhere, then press",
                          font: .systemFont(ofSize: 13))
        howTo.alignment = .center

        let key = label(shortcutLabel, font: .systemFont(ofSize: 26, weight: .medium))
        key.alignment = .center

        // The glyphs and the words, together. ⌃ and ⌥ are used by far more people than
        // can name them — ⌃ is regularly read as ⌘ or as a stray mark — and somebody who
        // cannot decode the symbols cannot use the app at all. Showing both costs one
        // line and removes the only step here that can silently fail.
        let keyWords = label(shortcutWords, font: .systemFont(ofSize: 12), secondary: true)
        keyWords.alignment = .center

        // A status line above the button, because the state it reports is the difference
        // between the app in the advert and a clipboard reader. Amber rather than red:
        // nothing is broken, it just is not set up yet, and red would say something has
        // gone wrong that the user has to repair.
        let statusIconView = NSImageView()
        statusIconView.imageScaling = .scaleProportionallyUpOrDown
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.widthAnchor.constraint(equalToConstant: 15).isActive = true
        statusIconView.heightAnchor.constraint(equalToConstant: 15).isActive = true
        statusIcon = statusIconView

        let statusLabel = label("", font: .systemFont(ofSize: 12, weight: .medium))
        statusText = statusLabel

        let statusRow = NSStackView(views: [statusIconView, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 5
        statusRow.alignment = .centerY

        let button = NSButton(title: "Turn on Select-to-Speak", target: self,
                              action: #selector(enableAccessibility))
        button.bezelStyle = .rounded
        button.controlSize = .large
        accessibilityButton = button

        let note = label(
            "Lets MoxSpeak read what you've selected. Without it, it reads whatever "
            + "you last copied.",
            font: .systemFont(ofSize: 11), secondary: true)
        note.alignment = .center
        accessibilityNote = note

        let login = NSButton(checkboxWithTitle: "Open MoxSpeak at login",
                             target: nil, action: nil)
        login.state = .on
        login.isHidden = !LaunchAtLogin.isAvailable
        loginCheckbox = login

        let start = NSButton(title: "Start", target: self, action: #selector(finish))
        start.bezelStyle = .rounded
        start.controlSize = .large
        startButton = start

        let privacy = label(
            "Sends anonymous usage stats. No text you select or copy ever leaves your "
            + "Mac. Turn it off under Advanced.",
            font: .systemFont(ofSize: 10), secondary: true)
        privacy.alignment = .center

        let stack = NSStackView(views: [
            icon, title, hint, whereItIs,
            separator(), howTo, key, keyWords, separator(),
            statusRow, button, note, login, start, privacy,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(4, after: icon)
        stack.setCustomSpacing(12, after: title)
        stack.setCustomSpacing(8, after: hint)
        stack.setCustomSpacing(14, after: whereItIs)
        stack.setCustomSpacing(2, after: howTo)
        stack.setCustomSpacing(1, after: key)
        stack.setCustomSpacing(16, after: keyWords)
        stack.setCustomSpacing(8, after: statusRow)
        stack.setCustomSpacing(6, after: button)
        stack.setCustomSpacing(18, after: note)
        stack.setCustomSpacing(18, after: login)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 30, bottom: 20, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 420),
        ])

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = content
        window.delegate = self
        window.level = .floating
        window.setContentSize(content.fittingSize)
        self.window = window
    }

    private func label(_ text: String, font: NSFont, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.isSelectable = false
        field.preferredMaxLayoutWidth = 360
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return box
    }

    // MARK: - Accessibility

    @objc private func enableAccessibility() {
        // The system prompt is modal-ish and opens System Settings. Trust is granted out
        // there, not here, so the button cannot report success — the poll below is what
        // notices, which is also what makes it work if they approve it much later.
        _ = actions.requestAccessibility()
        startPolling()
    }

    /// Accessibility approval happens in System Settings, and macOS sends no notification
    /// when it lands. Polling while this window is up is the only way to reflect it, and
    /// it stops the moment the window goes away.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibilityState() }
        }
    }

    /// Reflects the one thing on this window that can be in two states, and moves the
    /// emphasis with it.
    ///
    /// The first version of this got the hierarchy exactly backwards: "Start" was the
    /// default button, rendered blue and bound to Return, while "Turn on
    /// Select-to-Speak" sat beside it as an ordinary control. So the loudest thing on the
    /// window, and the one Return pressed, was the button that skips the only setup step
    /// there is. People did what the design told them to do.
    ///
    /// Now the emphasis is wherever the remaining work is. Off: an amber warning, the
    /// permission button is the default, and Start is demoted to "Skip for now" so
    /// choosing it is a decision rather than a reflex. On: a green check, the permission
    /// button becomes an inert confirmation, and Start becomes the default.
    private func refreshAccessibilityState() {
        guard let button = accessibilityButton, let start = startButton else { return }
        let trusted = actions.isAccessibilityTrusted()

        if trusted {
            statusIcon?.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                        accessibilityDescription: nil)
            statusIcon?.contentTintColor = .systemGreen
            statusText?.stringValue = "Select-to-Speak is on"
            statusText?.textColor = .secondaryLabelColor

            button.isEnabled = false
            button.title = "Select-to-Speak is on"
            button.keyEquivalent = ""
            accessibilityNote?.stringValue = "MoxSpeak will read whatever you've selected."

            start.title = "Start"
            start.keyEquivalent = "\r"

            pollTimer?.invalidate()
            pollTimer = nil
        } else {
            statusIcon?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                        accessibilityDescription: nil)
            statusIcon?.contentTintColor = .systemOrange
            statusText?.stringValue = "One step left"
            statusText?.textColor = .systemOrange

            button.isEnabled = true
            button.title = "Turn on Select-to-Speak"
            button.keyEquivalent = "\r"
            accessibilityNote?.stringValue =
                "Without this, MoxSpeak reads whatever you last copied instead of what "
                + "you've selected."

            start.title = "Skip for now"
            start.keyEquivalent = ""
        }
        // Only one button may own Return, and AppKit keeps its own pointer to it.
        window?.defaultButtonCell = (trusted ? start : button).cell as? NSButtonCell

        // Tint the primary action explicitly rather than relying on the default-button
        // highlight. AppKit only paints that blue while the window is key, and this window
        // can perfectly well be looked at without being focused — the first build of this
        // rendered both buttons identically grey, so the whole point of the hierarchy was
        // lost exactly when somebody was reading it rather than driving it.
        let primary = trusted ? start : button
        let secondary = trusted ? button : start
        primary.bezelColor = .controlAccentColor
        secondary.bezelColor = nil
    }

    // MARK: - Finishing

    @objc private func finish() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        // Closing the window *is* finishing, whichever control did it — the red button
        // and Start must not leave different amounts of setup done.
        actions.finish(loginCheckbox?.state == .on)
    }
}
