import Foundation
import CoreGraphics

// Monitors modifier keys for:
// - Double-Command tap (cmd+cmd): SKIP — kills audio + mic
// - Double-Option tap (opt+opt): PAUSE/RESUME — SIGSTOP/SIGCONT + chime on mic resume
//
// Usage: skip-listener [--timeout 300] [--debug]
// Requires: Accessibility permission (System Settings > Privacy & Security > Accessibility)

// MARK: - Constants

let stopFlag = "/tmp/claude-tts-skip-listener-stop"
let skipFlag = "/tmp/claude-tts-skip"
let pauseFlag = "/tmp/claude-tts-pause"
let ttsPlayingFlag = "/tmp/claude-tts-playing"
let micListeningFlag = "/tmp/claude-voice-listening"
let debugLogPath = "/tmp/claude-skip-listener-debug.log"
let chimeSound = "/System/Library/Sounds/Tink.aiff"
let doubleTapWindow: TimeInterval = 0.4
let enterKeyCode: Int64 = 36
let sendingFlag = "/tmp/claude-voice-input-sending"
let voiceInputStopFlag = "/tmp/claude-voice-input-stop"

// MARK: - Arguments

var timeout: TimeInterval = 300
var debug = false

if let idx = CommandLine.arguments.firstIndex(of: "--timeout"),
   idx + 1 < CommandLine.arguments.count,
   let t = TimeInterval(CommandLine.arguments[idx + 1]) {
    timeout = t
}
if CommandLine.arguments.contains("--debug") {
    debug = true
    try? "skip-listener started at \(Date())\n".write(
        toFile: debugLogPath, atomically: true, encoding: .utf8)
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

// MARK: - State

class ControlState {
    // Command double-tap (skip)
    var lastCommandUp: Date?
    var commandIsDown = false
    // Option double-tap (pause)
    var lastOptionUp: Date?
    var optionIsDown = false
    var isPaused = false
    // Voice active cache
    var voiceActive = false
    var lastVoiceCheck: Date = .distantPast
}

let state = ControlState()
var globalTap: CFMachPort?
let statePtr = Unmanaged.passUnretained(state).toOpaque()

// Remove stale flags
unlink(stopFlag)

// MARK: - Helpers

func isVoiceActive() -> Bool {
    let now = Date()
    if now.timeIntervalSince(state.lastVoiceCheck) > 0.5 {
        state.voiceActive = FileManager.default.fileExists(atPath: ttsPlayingFlag)
            || FileManager.default.fileExists(atPath: micListeningFlag)
        state.lastVoiceCheck = now
    }
    return state.voiceActive
}

func isMicActive() -> Bool {
    return FileManager.default.fileExists(atPath: micListeningFlag)
}

func playChime() {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    proc.arguments = [chimeSound]
    try? proc.run()
}

// MARK: - Pause/Resume

func togglePause() {
    let micActive = isMicActive()

    if state.isPaused {
        debugPrint("RESUME — sending SIGCONT")
        try? FileManager.default.removeItem(atPath: pauseFlag)

        for name in ["afplay", "say", "whisper-stream"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-CONT", name]
            try? proc.run()
            proc.waitUntilExit()
        }
        state.isPaused = false

        // Chime on mic resume so user knows mic is listening again
        if micActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { playChime() }
        }
    } else {
        debugPrint("PAUSE — sending SIGSTOP")
        FileManager.default.createFile(atPath: pauseFlag, contents: nil)

        for name in ["afplay", "say", "whisper-stream"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-STOP", name]
            try? proc.run()
            proc.waitUntilExit()
        }
        state.isPaused = true
    }
}

// MARK: - Skip

func triggerSkip() {
    debugPrint("SKIP — killing audio, creating skip flag")

    // If paused, resume first so processes can be killed cleanly
    if state.isPaused {
        for name in ["afplay", "say", "whisper-stream"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-CONT", name]
            try? proc.run()
            proc.waitUntilExit()
        }
        state.isPaused = false
    }

    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    try? FileManager.default.removeItem(atPath: pauseFlag)

    for name in ["say", "afplay"] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = [name]
        try? proc.run()
        proc.waitUntilExit()
    }

    debugPrint("Killed say + afplay, created skip flag")
}

// MARK: - CGEvent Callback

let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
    let state = Unmanaged<ControlState>.fromOpaque(userInfo!).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        debugPrint("Event tap disabled, re-enabling")
        if let tap = globalTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    // --- ENTER KEY: STOP VOICE SESSION (TTS + MIC) ---
    if type == .keyDown {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == enterKeyCode && isVoiceActive() {
            if !FileManager.default.fileExists(atPath: sendingFlag) {
                debugPrint("Enter pressed during voice session — stopping everything")
                DispatchQueue.main.async {
                    FileManager.default.createFile(atPath: voiceInputStopFlag, contents: nil)
                    FileManager.default.createFile(atPath: skipFlag, contents: nil)
                    for name in ["voice-input", "whisper-stream", "say", "afplay"] {
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                        proc.arguments = ["-f", name]
                        try? proc.run()
                        proc.waitUntilExit()
                    }
                    debugPrint("Voice session killed via Enter key (TTS + mic)")
                }
            } else {
                debugPrint("Enter pressed but sending flag present — ignoring (voice-input send)")
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // Command keys: 55 (left), 54 (right)
    let isCommandKey = (keyCode == 55 || keyCode == 54)
    // Option keys: 58 (left), 61 (right)
    let isOptionKey = (keyCode == 58 || keyCode == 61)

    if !isCommandKey && !isOptionKey {
        return Unmanaged.passUnretained(event)
    }

    // --- COMMAND DOUBLE-TAP: SKIP ---
    if isCommandKey {
        let hasCommand = flags.contains(.maskCommand)

        // Ignore if other modifiers held
        if !flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty {
            state.commandIsDown = false
            state.lastCommandUp = nil
            return Unmanaged.passUnretained(event)
        }

        debugPrint("Command flagsChanged: keyCode=\(keyCode) hasCommand=\(hasCommand)")

        if hasCommand && !state.commandIsDown {
            state.commandIsDown = true
        } else if !hasCommand && state.commandIsDown {
            state.commandIsDown = false
            let now = Date()

            if let last = state.lastCommandUp, now.timeIntervalSince(last) < doubleTapWindow {
                state.lastCommandUp = nil
                debugPrint("COMMAND DOUBLE TAP — triggering skip")
                DispatchQueue.main.async { triggerSkip() }
            } else {
                state.lastCommandUp = now
            }
        }
    }

    // --- OPTION DOUBLE-TAP: PAUSE/RESUME ---
    if isOptionKey {
        let hasOption = flags.contains(.maskAlternate)

        // Ignore if other modifiers held
        if !flags.intersection([.maskShift, .maskControl, .maskCommand]).isEmpty {
            state.optionIsDown = false
            state.lastOptionUp = nil
            return Unmanaged.passUnretained(event)
        }

        debugPrint("Option flagsChanged: keyCode=\(keyCode) hasOption=\(hasOption)")

        if hasOption && !state.optionIsDown {
            state.optionIsDown = true
        } else if !hasOption && state.optionIsDown {
            state.optionIsDown = false
            let now = Date()

            if let last = state.lastOptionUp, now.timeIntervalSince(last) < doubleTapWindow {
                state.lastOptionUp = nil
                if isVoiceActive() {
                    debugPrint("OPTION DOUBLE TAP — toggling pause")
                    DispatchQueue.main.async { togglePause() }
                } else {
                    debugPrint("OPTION DOUBLE TAP — ignored (no voice active)")
                }
            } else {
                state.lastOptionUp = now
            }
        }
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - Event Tap Setup

// flagsChanged for modifier double-taps + keyDown for Enter detection
let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
    | (1 << CGEventType.keyDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,  // No need to consume events — just modifier taps
    eventsOfInterest: eventMask,
    callback: callback,
    userInfo: statePtr
) else {
    let msg = "Error: Could not create event tap. Grant Accessibility permission: System Settings > Privacy & Security > Accessibility"
    fputs("\(msg)\n", stderr)
    debugPrint("FATAL: \(msg)")
    exit(1)
}

globalTap = tap
let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

debugPrint("Event tap created (listenOnly), listening for cmd+cmd skip + opt+opt pause + Enter stop")

// MARK: - Poll Timer

let startTime = Date()
let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    if Date().timeIntervalSince(startTime) >= timeout {
        debugPrint("Timeout reached (\(timeout)s), exiting")
        exit(0)
    }
    if FileManager.default.fileExists(atPath: stopFlag) {
        try? FileManager.default.removeItem(atPath: stopFlag)
        debugPrint("Stop flag detected, exiting")
        exit(0)
    }
}

RunLoop.current.add(timer, forMode: .common)
CFRunLoopRun()
