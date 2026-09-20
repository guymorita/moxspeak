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
/// ## Three steps, one idea each
///
/// This was one page, and it had grown three unrelated things competing for the same
/// glance: where the app lives, what to press, and a permission to grant. Nothing on it
/// was wrong and there was nowhere for the eye to land. Splitting it is not ceremony —
/// each screen now asks for exactly one thing, and the whole flow is still three clicks.
///
/// It is not a tour, not a wizard, and not a settings screen —
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
    private var step = 0
    private var content: NSStackView?
    private var dots: [NSView] = []
    private var backButton: NSButton?
    private var nextButton: NSButton?

    /// Invalidated in `windowWillClose`, which is the only way this window ends. Not in
    /// `deinit`: a nonisolated deinit cannot touch a main-actor, non-Sendable Timer under
    /// strict concurrency, and the controller outlives the window anyway.
    private var pollTimer: Timer?

    private var accessibilityButton: NSButton?
    private var accessibilityNote: NSTextField?
    private var statusIcon: NSImageView?
    private var statusText: NSTextField?
    private var loginCheckbox: NSButton?

    private static let stepCount = 3
    private static let permissionStep = 1

    init(shortcutLabel: String, shortcutWords: String, actions: Actions) {
        self.shortcutLabel = shortcutLabel
        self.shortcutWords = shortcutWords
        self.actions = actions
        super.init()
    }

    // MARK: - Showing

    func show(under statusItemFrame: CGRect?) {
        if window == nil { build() }
        guard let window else { return }
        step = 0
        render()
        position(window, under: statusItemFrame)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func position(_ window: NSWindow, under frame: CGRect?) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        let anchorX = frame.map { $0.midX } ?? (visible.maxX - 40)
        let x = min(max(visible.minX + 12, anchorX - size.width / 2),
                    visible.maxX - size.width - 12)
        let top = frame.map { $0.minY } ?? visible.maxY
        window.setFrameOrigin(CGPoint(x: x, y: top - size.height - 10))
    }

    // MARK: - Chrome

    private func build() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .centerX
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        content = body

        // Progress dots. Three of them, so somebody can see this ends.
        let dotRow = NSStackView()
        dotRow.orientation = .horizontal
        dotRow.spacing = 7
        for _ in 0..<Self.stepCount {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dots.append(dot)
            dotRow.addArrangedSubview(dot)
        }

        let back = NSButton(title: "Back", target: self, action: #selector(goBack))
        back.bezelStyle = .rounded
        back.isBordered = false
        back.contentTintColor = .secondaryLabelColor
        backButton = back

        let next = NSButton(title: "Next", target: self, action: #selector(goNext))
        next.bezelStyle = .rounded
        next.controlSize = .large
        next.keyEquivalent = "\r"
        next.bezelColor = .controlAccentColor
        nextButton = next

        let spacerLeft = NSView(), spacerRight = NSView()
        let bar = NSStackView(views: [back, spacerLeft, dotRow, spacerRight, next])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.distribution = .equalSpacing
        bar.translatesAutoresizingMaskIntoConstraints = false
        spacerLeft.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true
        spacerRight.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true

        container.addSubview(body)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 420),
            // Fixed height: the window must not jump as the steps swap, which reads as a
            // glitch and moves the button out from under the pointer.
            container.heightAnchor.constraint(equalToConstant: 366),
            // Centred in the space above the bar rather than pinned to the top. The
            // three steps hold different amounts, and top-anchoring left the shortest of
            // them sitting above a third of a window of nothing.
            body.centerYAnchor.constraint(equalTo: container.topAnchor, constant: 160),
            body.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 22),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 30),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -30),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
        ])

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = container
        window.delegate = self
        window.level = .floating
        window.setContentSize(NSSize(width: 420, height: 366))
        self.window = window
    }

    // MARK: - Steps

    @objc private func goNext() {
        if step == Self.stepCount - 1 { window?.close(); return }
        step += 1
        render()
    }

    @objc private func goBack() {
        guard step > 0 else { return }
        step -= 1
        render()
    }

    private func render() {
        guard let content else { return }
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }

        // Where it lives, then the permission, then the shortcut.
        //
        // The permission sits in the middle deliberately. It is the only step that sends
        // somebody out to System Settings, so it should not be the last thing standing
        // between them and being finished — and putting the shortcut last means the final
        // thing on screen is the thing to go and do, at the moment the window disappears.
        switch step {
        case 0: buildWhereItLives(into: content)
        case Self.permissionStep: buildThePermission(into: content)
        default: buildTheShortcut(into: content)
        }

        for (index, dot) in dots.enumerated() {
            dot.layer?.backgroundColor = (index == step
                ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
        }
        backButton?.isHidden = step == 0
        nextButton?.title = step == Self.stepCount - 1 ? "Start" : "Next"
        nextButton?.bezelColor = .controlAccentColor
        refreshAccessibilityState()
    }

    private func buildWhereItLives(into stack: NSStackView) {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = label("MoxSpeak", font: .systemFont(ofSize: 21, weight: .semibold))
        title.alignment = .center

        let hint = MenuBarHintView()

        let body = label("Look for this icon in your menu bar, at the top of your screen.",
                         font: .systemFont(ofSize: 13), secondary: true)
        body.alignment = .center

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(body)
        stack.setCustomSpacing(6, after: icon)
        stack.setCustomSpacing(20, after: title)
        stack.setCustomSpacing(14, after: hint)
    }

    private func buildTheShortcut(into stack: NSStackView) {
        let title = label("Select text, then press", font: .systemFont(ofSize: 18))
        title.alignment = .center

        let key = label(shortcutLabel, font: .systemFont(ofSize: 40, weight: .medium))
        key.alignment = .center

        let words = label(shortcutWords, font: .systemFont(ofSize: 13), secondary: true)
        words.alignment = .center

        let body = label("Anywhere: a web page, a document, an email. MoxSpeak reads what "
                         + "you have selected.", font: .systemFont(ofSize: 13), secondary: true)
        body.alignment = .center

        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(key)
        stack.addArrangedSubview(words)
        stack.addArrangedSubview(body)
        stack.setCustomSpacing(26, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(2, after: key)
        stack.setCustomSpacing(24, after: words)
    }

    private func buildThePermission(into stack: NSStackView) {
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

        let note = label("", font: .systemFont(ofSize: 12), secondary: true)
        note.alignment = .center
        accessibilityNote = note

        let login = NSButton(checkboxWithTitle: "Open MoxSpeak at login",
                             target: nil, action: nil)
        login.state = loginCheckbox?.state ?? .on
        login.isHidden = !LaunchAtLogin.isAvailable
        loginCheckbox = login

        let privacy = label("Sends anonymous usage stats. No text you select or copy ever "
                            + "leaves your Mac.", font: .systemFont(ofSize: 10), secondary: true)
        privacy.alignment = .center

        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(statusRow)
        stack.addArrangedSubview(button)
        stack.addArrangedSubview(note)
        stack.addArrangedSubview(login)
        stack.addArrangedSubview(privacy)
        stack.setCustomSpacing(30, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(12, after: statusRow)
        stack.setCustomSpacing(8, after: button)
        stack.setCustomSpacing(22, after: note)
        stack.setCustomSpacing(20, after: login)

        startPolling()
    }

    private func label(_ text: String, font: NSFont, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.isSelectable = false
        field.preferredMaxLayoutWidth = 356
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return field
    }

    // MARK: - Accessibility

    @objc private func enableAccessibility() {
        _ = actions.requestAccessibility()
        startPolling()
    }

    /// Approval happens in System Settings and macOS sends no notification when it lands,
    /// so polling while the permission step is up is the only way to reflect it.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibilityState() }
        }
    }

    /// The emphasis follows the remaining work. Not granted: an amber warning and the
    /// permission button is the loud one. Granted: a green check and Start is.
    private func refreshAccessibilityState() {
        guard let next = nextButton else { return }
        guard let button = accessibilityButton, step == Self.permissionStep else {
            next.bezelColor = .controlAccentColor
            return
        }
        let trusted = actions.isAccessibilityTrusted()

        if trusted {
            statusIcon?.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                        accessibilityDescription: nil)
            statusIcon?.contentTintColor = .systemGreen
            statusText?.stringValue = "Select-to-Speak is on"
            statusText?.textColor = .secondaryLabelColor
            button.isEnabled = false
            button.title = "Select-to-Speak is on"
            button.bezelColor = nil
            accessibilityNote?.stringValue = "MoxSpeak will read whatever you've selected."
            next.title = "Next"
            next.bezelColor = .controlAccentColor
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
            button.bezelColor = .controlAccentColor
            accessibilityNote?.stringValue =
                "Without this, MoxSpeak reads whatever you last copied instead of what "
                + "you've selected."
            next.title = "Skip for now"
            next.bezelColor = nil
        }
    }

    // MARK: - Finishing

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        // Closing the window is finishing, whichever control did it. The red button and
        // Start must not leave different amounts of setup done.
        actions.finish(loginCheckbox?.state != .off)
    }
}
