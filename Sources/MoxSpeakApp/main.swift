import AppKit
import ApplicationServices

/// Entry point and lifecycle wiring. Everything else lives in its own file.
///
/// `.accessory` is what makes this a menu bar app: no Dock icon, no menu bar menus of its
/// own, no window. `LSUIElement` in Info.plist says the same thing to LaunchServices
/// before the process starts, which stops the Dock icon flickering in at launch; setting
/// the policy here as well covers running the binary directly out of `.build` during
/// development, where there is no Info.plist at all.
@MainActor
final class MoxSpeakAppDelegate: NSObject, NSApplicationDelegate {

    /// The port the local engine is expected on. Overridable because the engine is not
    /// managed by this app — someone else started it, possibly somewhere else.
    private static var port: Int {
        guard let raw = ProcessInfo.processInfo.environment["MOXSPEAK_PORT"],
              let value = Int(raw) else { return 8880 }
        return value
    }

    private var controller: AppController?

    /// URLs that arrived before the controller existed.
    ///
    /// Opening a `moxspeak://` URL launches the app when it is not already running, and
    /// LaunchServices delivers the URL at the same moment — sometimes before
    /// `applicationDidFinishLaunching` has finished building anything to hand it to.
    /// Dropping those would make the scheme work reliably only on the second try, which
    /// is the kind of bug people write off as "it's flaky".
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Logged every launch as a standing invariant, not as a diagnostic. The app's
        // whole feature set — Carbon hotkeys, NSStatusItem, MPRemoteCommandCenter,
        // NSPasteboard — works untrusted, and false is the expected reading.
        //
        // Select-to-speak is the single exception, and it is an *upgrade*: true here
        // means the user went to System Settings and granted it deliberately, never that
        // the app asked. `AXIsProcessTrusted()` only reports; the one call that can raise
        // the system dialog lives behind a menu item (see `SelectionReader`) and nothing
        // on this path goes near it. If this reads true on a machine where nobody granted
        // anything, something has started asking for a permission this app must not need.
        let trusted = AXIsProcessTrusted()
        AppLog.write("launch: pid \(ProcessInfo.processInfo.processIdentifier), "
                     + "\(AppVersion.read().logLine), "
                     + "AXIsProcessTrusted=\(trusted) — select-to-speak "
                     + (trusted ? "available" : "off, reading the clipboard"))

        // The clipboard's starting line. Select-to-speak will speak a clipboard the user
        // has filled *since* MoxSpeak last acted on it; without a mark taken here, the
        // first press of a session would see a clipboard from yesterday, find no record
        // of having looked at it, and have to guess. Taking the baseline now means the
        // first press is judged by the same rule as every press after it.
        let clipboardBaseline = SelectionReader.recordClipboardBaseline()
        AppLog.write("clipboard: baseline change count \(clipboardBaseline) — anything "
                     + "copied from here on counts as freshly copied and will be spoken "
                     + "when nothing is selected; what is on it already will not")

        let controller = AppController(port: Self.port)
        self.controller = controller
        controller.start()

        let queued = pendingURLs
        pendingURLs = []
        for url in queued { open(url, with: controller) }
    }

    /// `moxspeak://speak`, `://pause`, `://stop`. The automation surface every launcher
    /// on macOS can already reach: Raycast, Alfred, Shortcuts, Keyboard Maestro, or
    /// `open` in a shell script. See `URLCommand`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let controller { open(url, with: controller) } else { pendingURLs.append(url) }
        }
    }

    private func open(_ url: URL, with controller: AppController) {
        guard let command = URLCommand(url) else {
            AppLog.write("url: ignored \(url.absoluteString) — not a command")
            return
        }
        controller.handle(command)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.write("terminate")
    }
}

// Before anything AppKit: `MOXSPEAK_SELFTEST=1` checks that this bundle can speak using
// only what is inside it, prints where each asset resolved from, and exits. It never
// returns, so no status item is created and no normal launch touches this line.
if NativeSelfTest.isRequested() {
    NativeSelfTest.run()
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// NSApplication holds its delegate weakly; this binding is what keeps it alive.
let delegate = MoxSpeakAppDelegate()
application.delegate = delegate

application.run()
