import Foundation
import CoreGraphics

// Monitors modifier keys and key combos for voice mode controls:
// - Double-Command tap (cmd+cmd): SKIP — kills audio + mic
// - Double-Option tap (opt+opt): PAUSE/RESUME — SIGSTOP/SIGCONT
// - Command+Shift (single tap): REPEAT — replay last TTS response
// - Option+Arrow (keyDown): FORWARD/REWIND — skip ±3 sentences
// - Option+Shift+Arrow (keyDown): MESSAGE NAV — play prev/next history message
// - Enter (keyDown): STOP — kills entire voice session
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
let leftArrowKeyCode: Int64 = 123
let rightArrowKeyCode: Int64 = 124
let sendingFlag = "/tmp/claude-voice-input-sending"
let voiceInputStopFlag = "/tmp/claude-voice-input-stop"

// Repeat state files
let lastTextFile = "/tmp/claude-tts-last-text"
let lastSpeedFile = "/tmp/claude-tts-last-speed"
let lastVolumeFile = "/tmp/claude-tts-last-volume"

// Forward/rewind flags
let forwardFlag = "/tmp/claude-tts-forward"
let rewindFlag = "/tmp/claude-tts-rewind"

// Message navigation flags
let nextMsgFlag = "/tmp/claude-tts-next-msg"
let prevMsgFlag = "/tmp/claude-tts-prev-msg"

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
    // Command+Shift (repeat)
    var cmdShiftTriggered = false
    // Track if a regular key was pressed while cmd+shift held (prevents false triggers)
    var regularKeyDuringCmdShift = false
    // Voice active cache
    var voiceActive = false
    var lastVoiceCheck: Date = .distantPast
    // Repeat playback state
    var repeatProcess: Process?
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

func isTTSPlaying() -> Bool {
    return FileManager.default.fileExists(atPath: ttsPlayingFlag)
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

func killTTSProcesses() {
    for name in ["say", "afplay"] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = [name]
        try? proc.run()
        proc.waitUntilExit()
    }
}

// Find the most recently active history directory
func findHistoryDir() -> String? {
    let fm = FileManager.default
    let tmpDir = "/tmp"
    guard let contents = try? fm.contentsOfDirectory(atPath: tmpDir) else { return nil }

    var bestDir: String?
    var bestDate: Date = .distantPast

    for name in contents where name.hasPrefix("claude-tts-history-") {
        let path = "\(tmpDir)/\(name)"
        let currentFile = "\(path)/current"
        if let attrs = try? fm.attributesOfItem(atPath: currentFile),
           let modDate = attrs[.modificationDate] as? Date,
           modDate > bestDate {
            bestDate = modDate
            bestDir = path
        }
    }
    return bestDir
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

    killTTSProcesses()

    debugPrint("Killed say + afplay, created skip flag")
}

// MARK: - Repeat (cmd+shift)

func triggerRepeat() {
    debugPrint("REPEAT — replaying last TTS response")

    // Kill any active TTS (original or previous repeat)
    killTTSProcesses()
    try? FileManager.default.removeItem(atPath: skipFlag)

    // Read saved state
    guard let text = try? String(contentsOfFile: lastTextFile, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        debugPrint("REPEAT — no saved text, ignoring")
        return
    }

    let speed = (try? String(contentsOfFile: lastSpeedFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "300"
    let volume = (try? String(contentsOfFile: lastVolumeFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "1.0"

    // Mark TTS as playing
    FileManager.default.createFile(atPath: ttsPlayingFlag, contents: nil)

    // Play sentence by sentence in background
    DispatchQueue.global(qos: .userInitiated).async {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var idx = 0
        while idx < sentences.count {
            if FileManager.default.fileExists(atPath: skipFlag) { break }

            // Check forward/rewind
            if FileManager.default.fileExists(atPath: forwardFlag) {
                try? FileManager.default.removeItem(atPath: forwardFlag)
                killTTSProcesses()
                idx = min(idx + 3, sentences.count - 1)
                continue
            }
            if FileManager.default.fileExists(atPath: rewindFlag) {
                try? FileManager.default.removeItem(atPath: rewindFlag)
                killTTSProcesses()
                idx = max(idx - 3, 0)
                continue
            }

            let sentence = sentences[idx]
            let tmpFile = "/tmp/claude-tts-repeat-\(ProcessInfo.processInfo.processIdentifier).aiff"

            // Generate audio
            let sayProc = Process()
            sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            sayProc.arguments = ["-r", speed, "-o", tmpFile]
            sayProc.standardInput = Pipe()
            let pipe = sayProc.standardInput as! Pipe
            pipe.fileHandleForWriting.write(sentence.data(using: .utf8)!)
            pipe.fileHandleForWriting.closeFile()
            try? sayProc.run()
            sayProc.waitUntilExit()

            if FileManager.default.fileExists(atPath: skipFlag) {
                try? FileManager.default.removeItem(atPath: tmpFile)
                break
            }

            // Play audio
            let playProc = Process()
            playProc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            playProc.arguments = ["--volume", volume, tmpFile]
            try? playProc.run()
            playProc.waitUntilExit()

            try? FileManager.default.removeItem(atPath: tmpFile)
            idx += 1
        }

        // Cleanup
        try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
        try? FileManager.default.removeItem(atPath: pauseFlag)
        try? FileManager.default.removeItem(atPath: skipFlag)
    }
}

// MARK: - Message Navigation (opt+shift+arrow)

func triggerMessageNav(direction: String) {
    debugPrint("MESSAGE NAV — \(direction)")

    // Kill any active TTS
    killTTSProcesses()
    try? FileManager.default.removeItem(atPath: skipFlag)

    // Find history directory
    guard let histDir = findHistoryDir() else {
        debugPrint("MESSAGE NAV — no history directory found")
        return
    }

    // Read current pointer and total
    guard let totalStr = try? String(contentsOfFile: "\(histDir)/total", encoding: .utf8),
          let total = Int(totalStr.trimmingCharacters(in: .whitespacesAndNewlines)),
          total > 0 else {
        debugPrint("MESSAGE NAV — no messages in history")
        return
    }

    let currentStr = (try? String(contentsOfFile: "\(histDir)/current", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "\(total)"
    var current = Int(currentStr) ?? total

    // Navigate
    if direction == "next" {
        if current >= total { debugPrint("MESSAGE NAV — already at last message"); return }
        current += 1
    } else {
        if current <= 1 { debugPrint("MESSAGE NAV — already at first message"); return }
        current -= 1
    }

    let padded = String(format: "%03d", current)
    let msgFile = "\(histDir)/msg-\(padded).txt"

    guard let text = try? String(contentsOfFile: msgFile, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        debugPrint("MESSAGE NAV — message file not found: \(msgFile)")
        return
    }

    let speed = (try? String(contentsOfFile: "\(histDir)/msg-\(padded).speed", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "300"
    let volume = (try? String(contentsOfFile: "\(histDir)/msg-\(padded).volume", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "1.0"

    // Update current pointer
    try? "\(current)".write(toFile: "\(histDir)/current", atomically: true, encoding: .utf8)

    // Also update last-text files so repeat plays this message
    try? text.write(toFile: lastTextFile, atomically: true, encoding: .utf8)
    try? speed.write(toFile: lastSpeedFile, atomically: true, encoding: .utf8)
    try? volume.write(toFile: lastVolumeFile, atomically: true, encoding: .utf8)

    // Mark TTS as playing and play
    FileManager.default.createFile(atPath: ttsPlayingFlag, contents: nil)

    DispatchQueue.global(qos: .userInitiated).async {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var idx = 0
        while idx < sentences.count {
            if FileManager.default.fileExists(atPath: skipFlag) { break }

            if FileManager.default.fileExists(atPath: forwardFlag) {
                try? FileManager.default.removeItem(atPath: forwardFlag)
                killTTSProcesses()
                idx = min(idx + 3, sentences.count - 1)
                continue
            }
            if FileManager.default.fileExists(atPath: rewindFlag) {
                try? FileManager.default.removeItem(atPath: rewindFlag)
                killTTSProcesses()
                idx = max(idx - 3, 0)
                continue
            }

            let sentence = sentences[idx]
            let tmpFile = "/tmp/claude-tts-nav-\(ProcessInfo.processInfo.processIdentifier).aiff"

            let sayProc = Process()
            sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            sayProc.arguments = ["-r", speed, "-o", tmpFile]
            sayProc.standardInput = Pipe()
            let pipe = sayProc.standardInput as! Pipe
            pipe.fileHandleForWriting.write(sentence.data(using: .utf8)!)
            pipe.fileHandleForWriting.closeFile()
            try? sayProc.run()
            sayProc.waitUntilExit()

            if FileManager.default.fileExists(atPath: skipFlag) {
                try? FileManager.default.removeItem(atPath: tmpFile)
                break
            }

            let playProc = Process()
            playProc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            playProc.arguments = ["--volume", volume, tmpFile]
            try? playProc.run()
            playProc.waitUntilExit()

            try? FileManager.default.removeItem(atPath: tmpFile)
            idx += 1
        }

        try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
        try? FileManager.default.removeItem(atPath: pauseFlag)
        try? FileManager.default.removeItem(atPath: skipFlag)
    }
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

    // --- KEY DOWN EVENTS ---
    if type == .keyDown {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Enter key: stop voice session
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
            return Unmanaged.passUnretained(event)
        }

        // Arrow keys with modifiers
        let isArrowKey = (keyCode == leftArrowKeyCode || keyCode == rightArrowKeyCode)
        if isArrowKey {
            let hasOption = flags.contains(.maskAlternate)
            let hasShift = flags.contains(.maskShift)
            let hasCommand = flags.contains(.maskCommand)
            let hasControl = flags.contains(.maskControl)

            // opt+shift+arrow: message navigation (works anytime, not just during TTS)
            if hasOption && hasShift && !hasCommand && !hasControl {
                let direction = (keyCode == rightArrowKeyCode) ? "next" : "prev"
                debugPrint("OPT+SHIFT+ARROW — message nav \(direction)")
                DispatchQueue.main.async { triggerMessageNav(direction: direction) }
                return Unmanaged.passUnretained(event)
            }

            // opt+arrow: forward/rewind (only during TTS playback)
            if hasOption && !hasShift && !hasCommand && !hasControl && isTTSPlaying() {
                if keyCode == rightArrowKeyCode {
                    debugPrint("OPT+RIGHT — forward 3 sentences")
                    FileManager.default.createFile(atPath: forwardFlag, contents: nil)
                    killTTSProcesses()
                } else {
                    debugPrint("OPT+LEFT — rewind 3 sentences")
                    FileManager.default.createFile(atPath: rewindFlag, contents: nil)
                    killTTSProcesses()
                }
                return Unmanaged.passUnretained(event)
            }
        }

        // Track regular keys during cmd+shift (prevents false triggers on cmd+shift+Z etc.)
        if flags.contains(.maskCommand) && flags.contains(.maskShift) {
            if keyCode != enterKeyCode && !isArrowKey {
                state.regularKeyDuringCmdShift = true
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
    // Shift keys: 56 (left), 60 (right)
    let isShiftKey = (keyCode == 56 || keyCode == 60)

    if !isCommandKey && !isOptionKey && !isShiftKey {
        return Unmanaged.passUnretained(event)
    }

    // --- COMMAND+SHIFT: REPEAT ---
    // Detect cmd+shift held together then released. Single tap, no double-tap needed.
    if isCommandKey || isShiftKey {
        let hasCommand = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)
        let hasControl = flags.contains(.maskControl)
        let hasOption = flags.contains(.maskAlternate)

        // When both cmd+shift are pressed (and no ctrl/opt)
        if hasCommand && hasShift && !hasControl && !hasOption {
            if !state.cmdShiftTriggered {
                state.cmdShiftTriggered = true
                state.regularKeyDuringCmdShift = false
                debugPrint("CMD+SHIFT down — armed for repeat")
            }
        }

        // When both are released (no modifiers left)
        if state.cmdShiftTriggered && !hasCommand && !hasShift {
            state.cmdShiftTriggered = false
            if !state.regularKeyDuringCmdShift {
                debugPrint("CMD+SHIFT released — triggering repeat")
                DispatchQueue.main.async { triggerRepeat() }
            } else {
                debugPrint("CMD+SHIFT released — ignored (regular key was pressed)")
            }
            state.regularKeyDuringCmdShift = false
        }

        // If cmd+shift was armed but one modifier released while other held, cancel
        if state.cmdShiftTriggered && ((!hasCommand && hasShift) || (hasCommand && !hasShift)) {
            // One released — still wait for full release
        }
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

// flagsChanged for modifier double-taps + keyDown for Enter/arrow detection
let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
    | (1 << CGEventType.keyDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
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

debugPrint("Event tap created (listenOnly), listening for all voice controls")

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
