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
final class SpeakeasyAppDelegate: NSObject, NSApplicationDelegate {

    /// The port the local engine is expected on. Overridable because the engine is not
    /// managed by this app — someone else started it, possibly somewhere else.
    private static var port: Int {
        guard let raw = ProcessInfo.processInfo.environment["SPEAKEASY_PORT"],
              let value = Int(raw) else { return 8880 }
        return value
    }

    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Logged every launch as a standing invariant, not as a diagnostic: this app is
        // built so that this stays false forever. Carbon hotkeys, NSStatusItem,
        // MPRemoteCommandCenter and NSPasteboard all work untrusted. If it ever reads
        // true, something has been added that asks the user for a permission this app
        // was designed never to need.
        AppLog.write("launch: pid \(ProcessInfo.processInfo.processIdentifier), "
                     + "AXIsProcessTrusted=\(AXIsProcessTrusted())")
        let controller = AppController(port: Self.port)
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.write("terminate")
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// NSApplication holds its delegate weakly; this binding is what keeps it alive.
let delegate = SpeakeasyAppDelegate()
application.delegate = delegate

application.run()
