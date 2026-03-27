import Foundation
import CoreGraphics

// Sends low-level key press combos via CGEvent (HID level)
// Triggers apps like Wispr Flow that monitor hardware key events
// Usage: send-key [keycode] [modifier_keycode] [hold_ms]
// Examples:
//   send-key 49 59 2000   — hold Control+Space for 2 seconds
//   send-key 59            — tap Control key

let keyCode = CGKeyCode(CommandLine.arguments.count > 1 ? UInt16(CommandLine.arguments[1]) ?? 49 : 49)
let modifierCode: CGKeyCode? = CommandLine.arguments.count > 2 ? CGKeyCode(UInt16(CommandLine.arguments[2]) ?? 0) : nil
let holdMs = CommandLine.arguments.count > 3 ? UInt32(CommandLine.arguments[3]) ?? 50 : 50

let source = CGEventSource(stateID: .hidSystemState)

// Press modifier first if specified
if let mod = modifierCode {
    if let modDown = CGEvent(keyboardEventSource: source, virtualKey: mod, keyDown: true) {
        modDown.post(tap: .cghidEventTap)
    }
    usleep(30000) // 30ms
}

// Key down
if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
    // Add modifier flag if Control
    if modifierCode == 59 || modifierCode == 62 {
        keyDown.flags = .maskControl
    }
    keyDown.post(tap: .cghidEventTap)
}

// Hold for specified duration
usleep(holdMs * 1000)

// Key up
if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
    if modifierCode == 59 || modifierCode == 62 {
        keyUp.flags = .maskControl
    }
    keyUp.post(tap: .cghidEventTap)
}

usleep(30000)

// Release modifier
if let mod = modifierCode {
    if let modUp = CGEvent(keyboardEventSource: source, virtualKey: mod, keyDown: false) {
        modUp.post(tap: .cghidEventTap)
    }
}
