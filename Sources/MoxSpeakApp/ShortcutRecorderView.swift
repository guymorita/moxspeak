import AppKit
import Carbon.HIToolbox

/// A field that captures a key combination: click it, press the keys, it takes them.
///
/// The conventional shape for this control, and the only one that works — you cannot
/// pick a shortcut from a list, because the point is the thing under your fingers.
///
/// ## Why this is a window control and not a menu row
///
/// Recording needs raw `keyDown` events. An open `NSMenu` runs its own modal
/// event-tracking loop and consumes every key for type-select and key equivalents, so a
/// custom view inside a menu never reliably sees them. That, not menu length, is why
/// `ShortcutsWindowController` exists: this control cannot live in the menu at all.
///
/// ## Why `performKeyEquivalent` and not just `keyDown`
///
/// AppKit offers a key-down event to the key-equivalent path first — main menu, then the
/// window's view hierarchy — and only delivers it as `keyDown` if nobody claimed it. So a
/// combination containing Command would be swallowed before `keyDown` ever ran, and ⌘⌥S
/// would be unrecordable while ⌃⌥S recorded fine. Claiming the event in
/// `performKeyEquivalent` while recording is what makes every combination equally
/// recordable; `keyDown` stays as the fallback for anything that reaches it instead.
///
/// Nothing here judges a combination. The view reports exactly what was pressed, including
/// combinations macOS will refuse to deliver — the window is what explains the refusal,
/// because "⌥⇧S cannot work, and here is why" is a far more useful answer than a field
/// that appears not to have noticed the keys at all.
@MainActor
final class ShortcutRecorderView: NSView {

    /// Fired with whatever was pressed. Validation is the caller's.
    var onCapture: ((Hotkey) -> Void)?

    private var hotkey: Hotkey
    private var isRecording = false
    /// Modifiers currently held, shown live while recording so the user can see the
    /// combination building up rather than typing into a field that looks dead.
    private var heldModifiers: UInt32 = 0

    static let preferredSize = NSSize(width: 190, height: 26)

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        toolTip = "Click, then press the combination you want."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    override var intrinsicContentSize: NSSize { Self.preferredSize }

    /// Pushes a combination in from outside — a rebinding that was accepted, one that was
    /// refused and has to be visibly undone, or Restore Defaults.
    func setHotkey(_ hotkey: Hotkey) {
        self.hotkey = hotkey
        needsDisplay = true
    }

    // MARK: - Recording

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = Hotkey.carbonModifiers(from: NSEvent.modifierFlags)
        needsDisplay = true
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        heldModifiers = 0
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        heldModifiers = Hotkey.carbonModifiers(from: event.modifierFlags)
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return false }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let modifiers = Hotkey.carbonModifiers(from: event.modifierFlags)

        // Escape on its own backs out. With modifiers it is a legitimate shortcut, so it
        // is only an escape hatch when it is pressed alone.
        if event.keyCode == UInt16(kVK_Escape), modifiers == 0 {
            endRecording()
            return
        }

        endRecording()
        onCapture?(Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)

        (isRecording ? NSColor.textBackgroundColor : NSColor.controlBackgroundColor).setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail

        let text: String
        let colour: NSColor
        if isRecording {
            let held = Hotkey.modifierLabel(for: heldModifiers)
            text = held.isEmpty ? "Press a combination…" : held + "…"
            colour = .secondaryLabelColor
        } else {
            text = hotkey.label
            colour = hotkey.isUsable ? .labelColor : .systemRed
        }

        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: colour, .paragraphStyle: style,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.minX, y: bounds.midY - size.height / 2)
        (text as NSString).draw(in: NSRect(x: origin.x, y: origin.y,
                                           width: bounds.width, height: size.height),
                                withAttributes: attributes)
    }

    /// The focus ring, so tabbing to this field is visible. Without it a keyboard user
    /// has no idea which row is about to record.
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
