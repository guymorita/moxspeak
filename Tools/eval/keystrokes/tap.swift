import CoreGraphics
import Foundation
// kVK_ANSI_S = 1, kVK_Space = 49, kVK_ANSI_Period = 47
let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let key: CGKeyCode
switch arg {
case "space": key = 49
case "period": key = 47
default: key = 1
}
let src = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)!
let up   = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)!
let flags: CGEventFlags = [.maskAlternate, .maskShift]
down.flags = flags; up.flags = flags
down.post(tap: .cgSessionEventTap)
usleep(60_000)
up.post(tap: .cgSessionEventTap)
print("posted key \(key) with option+shift")
