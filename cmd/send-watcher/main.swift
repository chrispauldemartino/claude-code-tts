import Foundation
import CoreGraphics

// Watches keystrokes for "send" keyword at end of input.
// When detected (after a silence pause): dismiss Wispr Flow, delete "send", press Enter.
// Usage: send-watcher [--timeout 60] [--debug]
//   --timeout: auto-exit after N seconds (default: 120)
//   --debug:   write debug log to /tmp/claude-send-watcher-debug.log

let stopFlag = "/tmp/claude-send-watcher-stop"
let debugLogPath = "/tmp/claude-send-watcher-debug.log"
let sendKeyBin: String = {
    let dir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    return dir + "/send-key"
}()

let silenceDelay: TimeInterval = 1.5  // seconds after "send" with no more typing
let maxBufferSize = 50

// Parse arguments
var timeout: TimeInterval = 120
var debug = false

if let idx = CommandLine.arguments.firstIndex(of: "--timeout"),
   idx + 1 < CommandLine.arguments.count,
   let t = TimeInterval(CommandLine.arguments[idx + 1]) {
    timeout = t
}
if CommandLine.arguments.contains("--debug") {
    debug = true
    try? "send-watcher started at \(Date())\n".write(toFile: debugLogPath, atomically: true, encoding: .utf8)
}

func debugPrint(_ msg: String) {
    guard debug else { return }
    let line = "\(Date()): \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: debugLogPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    }
}

// Remove stale stop flag
unlink(stopFlag)

// State
class WatcherState {
    var buffer: String = ""
    var lastKeystroke: Date = Date()
    var sendTimer: DispatchWorkItem?
    var triggered = false
}
let state = WatcherState()
let statePtr = Unmanaged.passUnretained(state).toOpaque()

// Global tap reference for re-enabling
var globalTap: CFMachPort?

func triggerSend() {
    guard !state.triggered else { return }
    state.triggered = true
    debugPrint("TRIGGER: dismissing Wispr, deleting 'send', pressing Enter")

    // Step 1: Dismiss Wispr Flow (Control+Space)
    let dismissWispr = Process()
    dismissWispr.executableURL = URL(fileURLWithPath: sendKeyBin)
    dismissWispr.arguments = ["49", "59", "1500"]  // Space + Control hold 1.5s
    try? dismissWispr.run()
    dismissWispr.waitUntilExit()

    usleep(300_000)  // 300ms wait for Wispr to fully dismiss

    let source = CGEventSource(stateID: .hidSystemState)

    // Step 2: Delete " send" — 5 backspaces (space + s + e + n + d)
    // Also handle "send." or "send " — check buffer for trailing punctuation
    var deleteCount = 4  // "send"
    let trimmed = state.buffer.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasSuffix("send.") || trimmed.lowercased().hasSuffix("send,") {
        deleteCount = 5  // "send" + punctuation
    }
    // Add 1 for the space before "send"
    if state.buffer.count > deleteCount {
        let idx = state.buffer.index(state.buffer.endIndex, offsetBy: -deleteCount)
        if idx > state.buffer.startIndex {
            let charBefore = state.buffer[state.buffer.index(before: idx)]
            if charBefore == " " {
                deleteCount += 1
            }
        }
    }

    debugPrint("Deleting \(deleteCount) characters")

    for _ in 0..<deleteCount {
        // Backspace key = keycode 51
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true) {
            keyDown.post(tap: .cghidEventTap)
        }
        usleep(20_000)
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }
        usleep(20_000)
    }

    usleep(100_000)  // 100ms

    // Step 3: Press Enter (Return key = keycode 36)
    debugPrint("Pressing Enter")
    if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true) {
        keyDown.post(tap: .cghidEventTap)
    }
    usleep(30_000)
    if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
        keyUp.post(tap: .cghidEventTap)
    }

    debugPrint("Send complete, exiting")
    usleep(200_000)
    exit(0)
}

func checkForSend() {
    let lower = state.buffer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    // Check if buffer ends with "send" (possibly followed by punctuation)
    let endsWithSend = lower.hasSuffix("send") ||
                       lower.hasSuffix("send.") ||
                       lower.hasSuffix("send,") ||
                       lower.hasSuffix("send!")

    if endsWithSend {
        debugPrint("Buffer ends with 'send', starting silence timer (\(silenceDelay)s)")

        // Cancel any existing timer
        state.sendTimer?.cancel()

        // Start silence timer — if no more keystrokes for silenceDelay, trigger
        let timer = DispatchWorkItem { triggerSend() }
        state.sendTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceDelay, execute: timer)
    } else {
        // Cancel pending trigger if buffer no longer ends with "send"
        state.sendTimer?.cancel()
        state.sendTimer = nil
    }
}

// CGEvent callback — monitors keyDown events
let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
    let state = Unmanaged<WatcherState>.fromOpaque(userInfo!).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    // Get the character typed
    var length = 4
    var chars = [UniChar](repeating: 0, count: 4)
    event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)

    if length > 0 {
        let typed = String(utf16CodeUnits: chars, count: length)
        state.lastKeystroke = Date()

        // Handle backspace — remove last char from buffer
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 51 {  // backspace
            if !state.buffer.isEmpty {
                state.buffer.removeLast()
            }
        } else {
            state.buffer += typed
            // Keep buffer manageable
            if state.buffer.count > maxBufferSize {
                state.buffer = String(state.buffer.suffix(maxBufferSize))
            }
        }

        debugPrint("Key: \(typed) (code \(keyCode)) | Buffer: '\(state.buffer.suffix(20))'")
        checkForSend()
    }

    return Unmanaged.passUnretained(event)
}

// Create event tap for keyDown events
let eventMask = (1 << CGEventType.keyDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(eventMask),
    callback: callback,
    userInfo: statePtr
) else {
    fputs("Error: Could not create event tap. Grant Accessibility permission.\n", stderr)
    exit(1)
}

globalTap = tap
let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

debugPrint("Event tap created, watching for 'send' keyword")

// Auto-exit timer + stop flag check
let startTime = Date()
let exitTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    if Date().timeIntervalSince(startTime) >= timeout {
        debugPrint("Timeout reached, exiting")
        exit(0)
    }
    if FileManager.default.fileExists(atPath: stopFlag) {
        try? FileManager.default.removeItem(atPath: stopFlag)
        debugPrint("Stop flag detected, exiting")
        exit(0)
    }
}
RunLoop.current.add(exitTimer, forMode: .common)
CFRunLoopRun()
