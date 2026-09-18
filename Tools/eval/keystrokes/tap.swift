import CoreGraphics
import Foundation

// Posts one of MoxSpeak's default hotkeys as a real HID-level key event, so the installed
// app is driven through the same path a human finger uses. Registration returning `noErr`
// says nothing about delivery — this is how you find out whether a hotkey actually fires.
//
//   swift tap.swift speak | pause | stop
//
// Then read ~/Library/Logs/MoxSpeak.log for the matching `hotkey: … fired` line. Keep this
// in step with `HotkeyAction.defaultHotkey`; posting a combination the app is not
// registered for looks exactly like a hotkey that is broken.
let actions: [String: (key: CGKeyCode, name: String)] = [
    "speak": (1, "S"),   // kVK_ANSI_S
    "pause": (8, "C"),   // kVK_ANSI_C
    "stop":  (7, "X"),   // kVK_ANSI_X
]

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "speak"
guard let action = actions[arg] else {
    print("unknown action \(arg) — expected one of \(actions.keys.sorted().joined(separator: ", "))")
    exit(1)
}

let src = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: src, virtualKey: action.key, keyDown: true)!
let up   = CGEvent(keyboardEventSource: src, virtualKey: action.key, keyDown: false)!
let flags: CGEventFlags = [.maskControl, .maskAlternate]
down.flags = flags; up.flags = flags
down.post(tap: .cgSessionEventTap)
usleep(60_000)
up.post(tap: .cgSessionEventTap)
print("posted ⌃⌥\(action.name) (\(arg))")
