import MoxSpeakCore

/// The pure logic behind the speed control: formatting a rate for display, and pulling a
/// dragged value onto a common speed when it lands close to one.
///
/// Kept separate from the slider view on purpose. `MenuBarController`'s speed row is an
/// `NSView` wired to a live `AVAudioUnitTimePitch`, and there is no honest way to unit
/// test a mouse drag — see `SpeedControlTests` for exactly what that leaves out. Every
/// decision that does not need a screen lives here instead, where it can be asserted
/// directly.
enum SpeedControl {

    /// The speeds worth a fast path — what the five preset menu items used to be. The
    /// slider snaps to these when a drag lands within `snapTolerance`; the exact-value
    /// field ignores them completely, because typing "1.3" is the user asking for a
    /// number that isn't one of these, and honoring that request is the whole reason the
    /// field exists.
    static let commonValues: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// How close a dragged value has to land to a common value before it snaps there.
    /// The slider spans `PlaybackEngine.rateRange` — 2.5 units of range — over roughly
    /// 220 points in the menu, so 0.03 is about 3 points either side of a tick: easy to
    /// land on by feel, narrow enough that someone deliberately parking on 1.05 still can.
    static let snapTolerance: Float = 0.03

    /// Clamps to what `PlaybackEngine.rate` will actually honour. Both the slider and the
    /// exact-value field route every value through this before applying it, so the UI
    /// never offers something the engine would silently rewrite — the whole point being
    /// that the menu and the ear agree, always.
    static func clamped(_ value: Float) -> Float {
        let range = PlaybackEngine.rateRange
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// What a slider drag should actually apply: clamped into range, then pulled onto the
    /// nearest common value if it landed within `snapTolerance` of one. This is the "fast
    /// path" — reaching exactly 1.0 or 1.5 by feel rather than by pixel precision — and it
    /// applies only to the slider. Typed values go through `clamped(_:)` alone.
    static func snapped(_ value: Float) -> Float {
        let clamped = clamped(value)
        guard let nearest = commonValues.min(by: { abs($0 - clamped) < abs($1 - clamped) }),
              abs(nearest - clamped) <= snapTolerance
        else { return clamped }
        return nearest
    }

    /// "1×", "1.25×", "0.75×" — a whole number drops the decimal; anything else keeps up
    /// to two places and trims a trailing zero, so 1.5 doesn't read as "1.50×" and 1.25
    /// doesn't round away to "1.3×". Used for the slider's live label, the exact-value
    /// field's contents, and the status line while speaking.
    static func format(_ value: Float) -> String {
        if value == value.rounded() { return "\(Int(value))×" }
        let rounded = (value * 100).rounded() / 100
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)×"
    }
}
