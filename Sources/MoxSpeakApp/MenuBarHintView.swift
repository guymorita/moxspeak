import AppKit
import QuartzCore

/// A small picture of the menu bar with MoxSpeak's icon in it, for the welcome window.
///
/// "MoxSpeak lives in your menu bar" is not enough on its own, and the reason is specific:
/// the app icon and the menu bar icon do not look alike. The app icon is a blue gem on a
/// pale tile; the menu bar shows a monochrome outline diamond that takes the system's text
/// colour. Somebody told to look for "MoxSpeak" scans the top of the screen for something
/// blue, does not find it, and concludes the app did not start.
///
/// So this draws the actual thing: the same `diamond` SF Symbol the status item uses, at
/// the size it renders there, in a strip that reads as a menu bar. The clock at the right
/// end is what makes it legible as the menu bar rather than as a toolbar, and the few dots
/// stand in for the neighbours every menu bar has. Without them a lone glyph in a rounded
/// rectangle reads as a button and people click it.
///
/// The halo pulses, faintly. It is the only moving thing on the window, and it is pointing
/// at the one piece of information somebody needs before they can use the app at all. It
/// stops entirely when the system asks for reduced motion.
final class MenuBarHintView: NSView {

    /// Must stay in step with `MenuBarController.setIcon`'s `.idle` case. Idle is the
    /// right state: it is what somebody sees when they go looking, because nothing is
    /// speaking yet.
    static let idleSymbolName = "diamond"

    private let halo = CAShapeLayer()
    private let glyph = CALayer()

    /// Sized to what it holds rather than to a round number. At 232 the diamond sat a
    /// clear 60pt from the nearest stand-in dot, which read as a gap rather than as a row
    /// of neighbours and made the strip look half empty.
    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: 34) }
    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(halo)
        layer?.addSublayer(glyph)
        halo.actions = ["opacity": NSNull()]   // no implicit fades on layout
        glyph.actions = ["contents": NSNull(), "position": NSNull()]
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Geometry

    /// Where the icon sits. Left of the stand-in dots, which are left of the clock, so the
    /// row reads right to left the way a real menu bar's status area does.
    private var glyphCentre: NSPoint {
        NSPoint(x: bounds.minX + 40, y: bounds.midY)
    }

    override func layout() {
        super.layout()
        let centre = glyphCentre
        halo.path = CGPath(ellipseIn: CGRect(x: centre.x - 14, y: centre.y - 14,
                                             width: 28, height: 28), transform: nil)
        halo.fillColor = NSColor.controlAccentColor.withAlphaComponent(1).cgColor
        halo.opacity = 0.18

        if let image = NSImage(systemSymbolName: Self.idleSymbolName,
                               accessibilityDescription: "MoxSpeak's menu bar icon"),
           let configured = image.withSymbolConfiguration(
               .init(pointSize: 15, weight: .regular)) {
            let tinted = NSImage(size: configured.size, flipped: false) { rect in
                NSColor.labelColor.set()
                configured.draw(in: rect)
                rect.fill(using: .sourceAtop)
                return true
            }
            glyph.contents = tinted
            glyph.contentsScale = window?.backingScaleFactor ?? 2
            glyph.frame = CGRect(x: centre.x - configured.size.width / 2,
                                 y: centre.y - configured.size.height / 2,
                                 width: configured.size.width,
                                 height: configured.size.height)
        }
        startPulse()
    }

    // MARK: - The pulse

    private func startPulse() {
        halo.removeAnimation(forKey: "pulse")
        // Reduced motion is not a preference to weigh against a nice effect. Somebody who
        // has asked the system for less movement gets a halo that simply sits there, and
        // the hint still works because the halo is what draws the eye, not its motion.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            halo.opacity = 0.18
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.10
        pulse.toValue = 0.30
        pulse.duration = 1.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(pulse, forKey: "pulse")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }

    // MARK: - The strip behind it

    override func draw(_ dirtyRect: NSRect) {
        let strip = bounds.insetBy(dx: 0.5, dy: 0.5)

        NSColor.textBackgroundColor.withAlphaComponent(0.85).setFill()
        let path = NSBezierPath(roundedRect: strip, xRadius: 8, yRadius: 8)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        // The clock, hard against the right end. It is the one thing in everyone's menu
        // bar in the same place, so it is what makes the strip legible as the menu bar.
        // With AM: a bare "9:41" reads as a duration rather than a time.
        let clock = NSAttributedString(string: "9:41 AM", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        let clockSize = clock.size()
        let clockX = strip.maxX - 10 - clockSize.width
        clock.draw(at: NSPoint(x: clockX, y: strip.midY - clockSize.height / 2))

        // Three stand-ins between the icon and the clock. Three, not seven: enough to say
        // "other things live here", few enough that the eye still goes to the diamond.
        NSColor.tertiaryLabelColor.setFill()
        var x = clockX - 16
        for _ in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: x - 7, y: strip.midY - 3.5,
                                        width: 7, height: 7)).fill()
            x -= 18
        }
    }
}
