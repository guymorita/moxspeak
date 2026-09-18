import AppKit
import MoxSpeakCore

/// The menu's speed row: "Speed" on the left, an editable exact value on the right, and
/// a full-range slider underneath — coarse and precise adjustment stacked in the same
/// row, both applying instantly.
///
/// `NSMenuItem.view` is what makes a slider possible inside an `NSMenu` at all, and this
/// is the whole reason it cannot be honestly unit tested: there is no way to script an
/// `NSSlider` drag or a keystroke into an `NSTextField` from `swift test` and trust the
/// result the way a pure function's return value can be trusted. Every decision that
/// *can* be pulled out into something testable has been — see `SpeedControl` — so what is
/// left here is wiring: controls kept in sync, both ends routed through the same closure
/// `MenuBarController` uses for every other action.
///
/// Frame-based rather than Auto Layout. A custom menu-item view is a small, fixed-size
/// thing that never resizes after the menu is built, which is exactly the case Auto
/// Layout is overhead for.
///
/// Two measurements below are *not* AppKit constants — there aren't any public ones for
/// a standard menu item's own text inset — they were read off this exact menu with a
/// ruler (screenshot the running app, measure the gap between the menu's edge and where
/// "Voice" or "Speak Clipboard" actually starts drawing) after the owner flagged the
/// first pass as visibly misaligned. A plain-text `NSMenuItem` gets that inset from
/// AppKit automatically; a view-based one gets none of it and has to supply its own, or
/// its content sits flush against the menu's edge while every item above and below it
/// does not.
@MainActor
final class SpeedControlView: NSView {

    /// Fired with the value to actually apply — already clamped, and snapped when the
    /// change came from a slider drag near a common value. `MenuBarController` wires this
    /// straight to `Actions.selectRate`, the same closure the rest of the menu uses.
    var onChange: ((Float) -> Void)?

    /// Left edge of a standard menu item's title, and the mirrored gap kept on the
    /// right — measured against "Voice" and the submenu chevron on "Engine".
    /// 21, not 24. Measured rather than guessed: screenshot the open menu, find the
    /// leftmost inked pixel of each row, and the plain items ("Voice", "Engine", "Quit")
    /// all land on the same column. At 24 this row sat three points right of them, which
    /// reads as a wobble in the left edge of the whole menu.
    private static let leftInset: CGFloat = 21
    private static let rightInset: CGFloat = 20

    /// Wide enough to be the widest thing in the menu itself, so this row defines the
    /// menu's width rather than hoping it is already at least as wide as "Speak
    /// Clipboard  (⌥⇧S reads the selection)". A view narrower than the menu (sized by
    /// some other item) does not get stretched to fit — it just leaves a gap on its own
    /// row, which was the other half of what looked wrong here.
    private static let width: CGFloat = 324
    private static let height: CGFloat = 58

    /// The menu's own title font and size, so "Speed" reads identically to "Voice" and
    /// "Engine: Built in" beside it rather than picking its own.
    private static let menuFont = NSFont.menuFont(ofSize: 0)

    /// Same size as `menuFont`, but with tabular figures. Without this, "0.75×" and
    /// "1.25×" are different widths in a proportional font, and every drag or keystroke
    /// nudges the number sideways — the exact kind of jitter that reads as sloppy.
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: menuFont.pointSize,
                                                                     weight: .regular)

    private let label = NSTextField(labelWithString: "Speed")
    private let valueField = NSTextField()
    private let timesLabel = NSTextField(labelWithString: "×")
    private let slider = NSSlider()
    private let minLabel = NSTextField(labelWithString: SpeedControl.format(PlaybackEngine.rateRange.lowerBound))
    private let maxLabel = NSTextField(labelWithString: SpeedControl.format(PlaybackEngine.rateRange.upperBound))

    /// The last value pushed or applied. Used to restore the field when it is given
    /// something that doesn't parse, and to answer `fieldChanged` when the field was
    /// cleared rather than edited.
    private var current: Float = Settings.defaultRate

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("SpeedControlView is built in code, not a nib")
    }

    private func setUp() {
        let contentRight = Self.width - Self.rightInset

        label.font = Self.menuFont
        label.frame = NSRect(x: Self.leftInset, y: 38, width: 80, height: 18)

        // The exact-value field and its "×" sit flush with the right inset, immediately
        // adjacent, reading as one "1.25×" — but the number is a real, borderless,
        // editable `NSTextField` and the "×" is a fixed label glued beside it. Splitting
        // it this way means editing never fights a formatter's suffix (typing "1.4" into
        // a field whose formatter insists on rendering "1.4×" mid-edit is exactly the
        // kind of thing that traps the cursor in the wrong place), while still reading
        // as plain text rather than a boxed control — nothing here is bordered or filled,
        // so it looks like part of the menu, not a dialog dropped into it.
        timesLabel.font = Self.menuFont
        timesLabel.frame = NSRect(x: contentRight - 10, y: 38, width: 10, height: 18)

        valueField.frame = NSRect(x: contentRight - 54, y: 38, width: 44, height: 18)
        valueField.alignment = .right
        valueField.font = Self.valueFont
        valueField.isBordered = false
        valueField.isBezeled = false
        valueField.drawsBackground = false
        valueField.focusRingType = .none
        valueField.formatter = Self.numberFormatter
        valueField.target = self
        valueField.action = #selector(fieldChanged)
        valueField.delegate = self
        valueField.toolTip = "Exact speed, \(SpeedControl.format(PlaybackEngine.rateRange.lowerBound)) to "
                            + "\(SpeedControl.format(PlaybackEngine.rateRange.upperBound))"

        slider.minValue = Double(PlaybackEngine.rateRange.lowerBound)
        slider.maxValue = Double(PlaybackEngine.rateRange.upperBound)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.frame = NSRect(x: Self.leftInset, y: 20, width: Self.width - Self.leftInset - Self.rightInset,
                              height: 16)

        // Pinned to the slider's own ends rather than to the row's text inset — they are
        // labelling the slider, not standing in the same column as "Speed", and lining
        // them up with the control they describe reads as intentional in a way lining
        // them up with unrelated text above would not.
        for l in [minLabel, maxLabel] {
            l.font = .systemFont(ofSize: 9)
            l.textColor = .secondaryLabelColor
        }
        minLabel.frame = NSRect(x: slider.frame.minX, y: 4, width: 30, height: 12)
        maxLabel.frame = NSRect(x: slider.frame.maxX - 30, y: 4, width: 30, height: 12)
        maxLabel.alignment = .right

        for view in [label, timesLabel, valueField, slider, minLabel, maxLabel] {
            addSubview(view)
        }

        setSpeed(current)
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.minimum = NSNumber(value: PlaybackEngine.rateRange.lowerBound)
        formatter.maximum = NSNumber(value: PlaybackEngine.rateRange.upperBound)
        return formatter
    }()

    /// Pushes a rate into every part of the row: the slider's thumb and the exact-value
    /// field. Called on launch, on reset, and after every applied change — including the
    /// row's own — so the field and slider never drift apart from each other or from
    /// what is actually playing.
    func setSpeed(_ rate: Float) {
        current = rate
        slider.floatValue = rate
        valueField.objectValue = NSNumber(value: rate)
    }

    /// Fires continuously while the user drags. The value applied is snapped toward a
    /// common speed when the drag lands close to one — see `SpeedControl.snapped` — but
    /// the slider's own thumb is deliberately left wherever the mouse put it: pulling it
    /// out from under an active drag would fight the gesture producing it. A menu reopen
    /// straightens the thumb out via `setSpeed`.
    @objc private func sliderChanged() {
        let value = SpeedControl.snapped(Float(slider.doubleValue))
        current = value
        valueField.objectValue = NSNumber(value: value)
        onChange?(value)
    }

    /// Fires on Return (the field's own action) and on losing focus (`controlTextDidEndEditing`
    /// below) — either is "the user is done typing". Unparsable or out-of-range text is
    /// clamped rather than rejected outright, and the field is always rewritten from
    /// `current` afterward so it never shows something that was not actually applied.
    @objc private func fieldChanged() {
        let value = SpeedControl.clamped((valueField.objectValue as? NSNumber)?.floatValue ?? current)
        onChange?(value)
        setSpeed(value)
    }
}

extension SpeedControlView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        fieldChanged()
    }
}
