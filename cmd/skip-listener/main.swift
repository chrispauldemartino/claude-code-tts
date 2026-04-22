import Foundation
import CoreGraphics
import ApplicationServices

// Monitors modifier keys and key combos for voice mode controls:
// - Double-Command tap (cmd+cmd): SKIP — kills audio + mic
// - Double-Option tap (opt+opt): PAUSE/RESUME — SIGSTOP/SIGCONT
// - Command+Shift (single tap): REPEAT — replay last TTS response
// - Option+Arrow (keyDown): FORWARD/REWIND — skip ±1 sentence
// - Option+Shift+Arrow (keyDown): MESSAGE NAV — play prev/next history message
// - Enter (keyDown): STOP — kills entire voice session
//
// Usage: skip-listener [--debug]
// Runs as persistent daemon. Idles when /tmp/claude-voice-config is removed.
// Requires: Accessibility + Input Monitoring permission
//           (System Settings > Privacy & Security > Accessibility AND Input Monitoring)

// MARK: - Constants

let configFile = "/tmp/claude-voice-config"
let pidFile = "/tmp/claude-skip-listener.pid"
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
let downArrowKeyCode: Int64 = 125
let upArrowKeyCode: Int64 = 126
let sendingFlag = "/tmp/claude-voice-input-sending"
let voiceInputStopFlag = "/tmp/claude-voice-input-stop"
let minSpeechSpeed = 150
let maxSpeechSpeed = 450
let speechSpeedStep = 25

// Repeat state files
let lastTextFile = "/tmp/claude-tts-last-text"
let lastSpeedFile = "/tmp/claude-tts-last-speed"
let lastVolumeFile = "/tmp/claude-tts-last-volume"
let lastSourceFile = "/tmp/claude-tts-last-source"
let lastSessionFile = "/tmp/claude-tts-last-session"
let playbackCursorFile = "/tmp/claude-tts-playback-cursor"

// Forward/rewind flags
let forwardFlag = "/tmp/claude-tts-forward"
let rewindFlag = "/tmp/claude-tts-rewind"
let bigForwardFlag = "/tmp/claude-tts-big-forward"   // 20-line skip during file read
let bigRewindFlag = "/tmp/claude-tts-big-rewind"     // 20-line skip during file read

// Message navigation — reads from transcript JSONL
let transcriptPathFile = "/tmp/claude-tts-transcript-path"
let navIndexFile = "/tmp/claude-tts-nav-index"

// Repeat anchor — tracks where repeat starts from in session history
let repeatAnchorFile = "/tmp/claude-tts-repeat-anchor"
let blockStartFile = "/tmp/claude-tts-block-start"
let historyDirFile = "/tmp/claude-tts-history-dir"

// TTS queue — auto-speak.sh writes entries here, daemon reads and speaks
let queueDir = "/tmp/claude-tts-queue"

// File reading state — set by read-file.sh when reading a doc aloud
let readingFileFlag = "/tmp/claude-tts-reading-file"

// Drill-down cache for structured data (tables/lists)
let detailCacheDir = "/tmp/claude-tts-detail-cache"
let detailIndexFile = "/tmp/claude-tts-detail-cache/index.txt"
let drillDownFlag = "/tmp/claude-tts-drill-down"
let drillDownIndexFile = "/tmp/claude-tts-detail-cache/drill-index"
let activeSegmentFile = "/tmp/claude-tts-active-segment"

// MARK: - Arguments

var debug = false
let doctorMode = CommandLine.arguments.contains("--doctor")

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

func cleanupAndExit() {
    // Remove PID file if it still points to us
    if let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8),
       let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
       pid == ProcessInfo.processInfo.processIdentifier {
        try? FileManager.default.removeItem(atPath: pidFile)
    }
    debugPrint("Exiting cleanly")
    exit(0)
}

// MARK: - State

class ControlState {
    // Command double-tap (skip segment)
    var lastCommandUp: Date?
    var commandIsDown = false
    // Option double-tap (pause)
    var lastOptionUp: Date?
    var optionIsDown = false
    var lastOptionComboUse: Date?
    var isPaused = false
    // Shift double-tap (stop all)
    var lastShiftUp: Date?
    var shiftIsDown = false
    // Command+Shift (repeat)
    var cmdShiftTriggered = false
    // Track if a regular key was pressed while cmd+shift held (prevents false triggers)
    var regularKeyDuringCmdShift = false
    // Option+Shift double-tap (drill-down)
    var optShiftTriggered = false
    var lastOptShiftUp: Date?
    // Voice active cache
    var voiceActive = false
    var lastVoiceCheck: Date = .distantPast
    // Repeat playback state
    var repeatProcess: Process?
    var lastStatusLine = ""
    // Queue processing state
    var isProcessingQueue = false
}

let state = ControlState()
var globalTap: CFMachPort?
let statePtr = Unmanaged.passUnretained(state).toOpaque()

// Write PID file for daemon management
let myPid = ProcessInfo.processInfo.processIdentifier
try? "\(myPid)".write(toFile: pidFile, atomically: true, encoding: .utf8)

// MARK: - Helpers

func isVoiceActive() -> Bool {
    let now = Date()
    if now.timeIntervalSince(state.lastVoiceCheck) > 0.3 {
        state.voiceActive = FileManager.default.fileExists(atPath: ttsPlayingFlag)
            || FileManager.default.fileExists(atPath: micListeningFlag)
            || FileManager.default.fileExists(atPath: readingFileFlag)
            || state.isProcessingQueue
        state.lastVoiceCheck = now
    }
    return state.voiceActive
}

func isTTSPlaying() -> Bool {
    return FileManager.default.fileExists(atPath: ttsPlayingFlag)
}

func isReadingFile() -> Bool {
    return FileManager.default.fileExists(atPath: readingFileFlag)
}

func isMicActive() -> Bool {
    return FileManager.default.fileExists(atPath: micListeningFlag)
}

func hasVoiceConfig() -> Bool {
    return FileManager.default.fileExists(atPath: configFile)
}

let chimeVolume = "0.3"  // 0.0–1.0, keeps chime subtle

func playChime() {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    proc.arguments = ["--volume", chimeVolume, chimeSound]
    try? proc.run()
}

func playDoubleTink() {
    let proc1 = Process()
    proc1.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    proc1.arguments = ["--volume", chimeVolume, chimeSound]
    try? proc1.run()
    proc1.waitUntilExit()
    usleep(80_000)
    let proc2 = Process()
    proc2.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    proc2.arguments = ["--volume", chimeVolume, chimeSound]
    try? proc2.run()
    proc2.waitUntilExit()
}

// MARK: - Status Line

func readActiveSegment() -> (segment: Int, total: Int, preview: String, status: String)? {
    guard let content = try? String(contentsOfFile: activeSegmentFile, encoding: .utf8) else {
        return nil
    }
    var seg = 0, total = 0, preview = "", status = ""
    for line in content.components(separatedBy: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = String(parts[0])
        let val = String(parts[1])
        switch key {
        case "segment": seg = Int(val) ?? 0
        case "total": total = Int(val) ?? 0
        case "preview": preview = val
        case "status": status = val
        default: break
        }
    }
    guard seg > 0 && !status.isEmpty else { return nil }
    return (seg, total, preview, status)
}

func updateStatusLine() {
    if let info = readActiveSegment() {
        let line: String
        switch info.status {
        case "speaking":
            line = "▶ Speaking [\(info.segment)/\(info.total)]: \(info.preview)"
        case "drill-down":
            line = "▶ Drill-down: \(info.preview)"
        case "repeat":
            line = "▶ Repeat: \(info.preview)"
        default:
            clearStatusLine()
            return
        }
        let truncated = String(line.prefix(80))
        if truncated != state.lastStatusLine {
            let clearStr = "\r" + String(repeating: " ", count: state.lastStatusLine.count) + "\r"
            fputs(clearStr + truncated, stderr)
            state.lastStatusLine = truncated
        }
    } else if !state.lastStatusLine.isEmpty {
        clearStatusLine()
    }
}

func clearStatusLine() {
    if !state.lastStatusLine.isEmpty {
        let clearStr = "\r" + String(repeating: " ", count: state.lastStatusLine.count) + "\r"
        fputs(clearStr, stderr)
        state.lastStatusLine = ""
    }
}

// MARK: - TTY Subtitle (direct terminal output)

let ttyPathFile = "/tmp/claude-tts-tty"

func readSubtitleEnabled() -> Bool {
    readConfigValue("subtitle") == "on"
}

func showTTYSubtitle(_ text: String) {
    guard readSubtitleEnabled(),
          let ttyPath = try? String(contentsOfFile: ttyPathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
          let fh = FileHandle(forWritingAtPath: ttyPath) else { return }
    // Get terminal width from TTY
    var ws = winsize()
    let cols: Int
    if ioctl(fh.fileDescriptor, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
        cols = Int(ws.ws_col)
    } else {
        cols = 120
    }
    let maxLen = cols - 4
    var preview = text
    if preview.count > maxLen { preview = String(preview.prefix(maxLen)) }
    let line = "\r\u{1B}[K\u{1B}[90m▶ \(preview)\u{1B}[0m"
    if let data = line.data(using: .utf8) { fh.write(data) }
    fh.closeFile()
}

func clearTTYSubtitle() {
    guard let ttyPath = try? String(contentsOfFile: ttyPathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
          let fh = FileHandle(forWritingAtPath: ttyPath) else { return }
    if let data = "\r\u{1B}[K".data(using: .utf8) { fh.write(data) }
    fh.closeFile()
}

func normalizeSourceLabel(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func normalizeSessionID(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func permissionTargetPath() -> String {
    let bundlePath = Bundle.main.bundleURL.path
    if bundlePath.hasSuffix(".app") {
        return bundlePath
    }

    let exePath = CommandLine.arguments[0]
    if let range = exePath.range(of: ".app/Contents/MacOS/") {
        return String(exePath[..<range.lowerBound]) + ".app"
    }

    return exePath
}

let doctorTapCallback: CGEventTapCallBack = { _, _, event, _ in
    Unmanaged.passUnretained(event)
}

func runDoctor() -> Never {
    let permissionTarget = permissionTargetPath()
    let trusted = AXIsProcessTrusted()
    let listenGranted = CGPreflightListenEventAccess()
    let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        | (1 << CGEventType.keyDown.rawValue)

    var tapCreated = false
    var tapEnabled = false
    if let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: eventMask,
        callback: doctorTapCallback,
        userInfo: nil
    ) {
        tapCreated = true
        tapEnabled = CGEvent.tapIsEnabled(tap: tap)
        CFMachPortInvalidate(tap)
    }

    print("permission_target=\(permissionTarget)")
    print("accessibility_trusted=\(trusted)")
    print("input_monitoring_granted=\(listenGranted)")
    print("event_tap_created=\(tapCreated)")
    print("event_tap_enabled=\(tapEnabled)")

    let ok = trusted && listenGranted && tapCreated && tapEnabled
    print("status=\(ok ? "ok" : "fail")")
    exit(ok ? 0 : 1)
}

func writeActiveSegment(segment: Int = 1, total: Int = 1, preview: String, status: String) {
    let truncPreview = String(preview.prefix(60))
    let content = "segment=\(segment)\ntotal=\(total)\npreview=\(truncPreview)\nstatus=\(status)\n"
    try? content.write(toFile: activeSegmentFile, atomically: true, encoding: .utf8)
}

func clearActiveSegment() {
    try? FileManager.default.removeItem(atPath: activeSegmentFile)
}

func readConfigValue(_ key: String) -> String {
    guard let content = try? String(contentsOfFile: configFile, encoding: .utf8) else { return "" }
    for line in content.components(separatedBy: "\n") {
        if line.hasPrefix("\(key)=") {
            return String(line.dropFirst(key.count + 1))
        }
    }
    return ""
}

func writeConfigValue(_ key: String, value: String) {
    let content = (try? String(contentsOfFile: configFile, encoding: .utf8)) ?? ""
    var lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    var updated = false

    for idx in lines.indices {
        if lines[idx].hasPrefix("\(key)=") {
            lines[idx] = "\(key)=\(value)"
            updated = true
            break
        }
    }

    if !updated {
        lines.append("\(key)=\(value)")
    }

    let serialized = lines.joined(separator: "\n") + "\n"
    try? serialized.write(toFile: configFile, atomically: true, encoding: .utf8)
}

func currentSpeechSpeed(fallback: String = "300") -> String {
    let value = readConfigValue("speed")
    return value.isEmpty ? fallback : value
}

typealias PlaybackContext = (
    text: String,
    speed: String,
    volume: String,
    sourceLabel: String?,
    sessionID: String?
)

func splitSentences(_ text: String) -> [String] {
    text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

func writePlaybackCursor(_ index: Int) {
    try? "\(index)".write(toFile: playbackCursorFile, atomically: true, encoding: .utf8)
}

func readPlaybackCursor() -> Int {
    if let raw = try? String(contentsOfFile: playbackCursorFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       let cursor = Int(raw), cursor >= 0 {
        return cursor
    }
    return 0
}

func markOptionComboUse() {
    state.lastOptionComboUse = Date()
    state.lastOptionUp = nil
}

func playbackPreview(_ context: PlaybackContext) -> String {
    let previewBase = String(context.text.prefix(60))
    if let source = context.sourceLabel {
        return "[\(source)] \(previewBase)"
    }
    return previewBase
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

func runProcessWithTimeout(_ process: Process, timeout: TimeInterval) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        semaphore.signal()
    }

    do {
        try process.run()
    } catch {
        debugPrint("PROCESS — failed to launch: \(error)")
        return false
    }

    if semaphore.wait(timeout: .now() + timeout) == .success {
        return process.terminationStatus == 0
    }

    debugPrint("PROCESS — timed out after \(timeout)s: \(process.executableURL?.path ?? "unknown")")
    process.terminate()
    usleep(200_000)
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    _ = semaphore.wait(timeout: .now() + 1)
    return false
}

func waitWhilePaused() -> Bool {
    while FileManager.default.fileExists(atPath: pauseFlag) {
        state.isPaused = true
        if FileManager.default.fileExists(atPath: skipFlag) {
            return false
        }
        usleep(150_000)
    }
    state.isPaused = false
    return true
}

func synthesizeSpeechAudio(_ spokenText: String, speed: String, outputFile: String) -> Bool {
    let textFile = "/tmp/claude-tts-say-\(ProcessInfo.processInfo.processIdentifier).txt"
    try? spokenText.write(toFile: textFile, atomically: true, encoding: .utf8)

    let sayProc = Process()
    sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    sayProc.arguments = ["-r", currentSpeechSpeed(fallback: speed), "-f", textFile, "-o", outputFile]
    let success = runProcessWithTimeout(sayProc, timeout: 15)
    try? FileManager.default.removeItem(atPath: textFile)

    if !success {
        try? FileManager.default.removeItem(atPath: outputFile)
        return false
    }

    return FileManager.default.fileExists(atPath: outputFile)
}

func playAudioFile(_ path: String, volume: String) -> Bool {
    let playProc = Process()
    playProc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    playProc.arguments = ["--volume", volume, path]
    return runProcessWithTimeout(playProc, timeout: 20)
}

// Audio mutex — same lock as auto-speak.sh so repeat/nav don't overlap with hook TTS
let ttsLockDir = "/tmp/claude-tts-speaking.lock"
let ttsLockPidFile = "/tmp/claude-tts-speaking.lock/pid"

func acquireTTSLock() {
    let fm = FileManager.default
    while true {
        do {
            try fm.createDirectory(atPath: ttsLockDir, withIntermediateDirectories: false)
            try "\(ProcessInfo.processInfo.processIdentifier)".write(
                toFile: ttsLockPidFile, atomically: true, encoding: .utf8)
            debugPrint("TTS lock acquired")
            return
        } catch {
            // Lock exists — check if holder is alive
            if let pidStr = try? String(contentsOfFile: ttsLockPidFile, encoding: .utf8),
               let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if kill(pid, 0) == 0 {
                    // Holder alive — wait
                    usleep(300_000)
                } else {
                    // Stale lock — reclaim
                    try? fm.removeItem(atPath: ttsLockDir)
                    debugPrint("Removed stale TTS lock (pid \(pid) dead)")
                }
            } else {
                try? fm.removeItem(atPath: ttsLockDir)
            }
        }
    }
}

func releaseTTSLock() {
    try? FileManager.default.removeItem(atPath: ttsLockDir)
    debugPrint("TTS lock released")
}

// MARK: - Pause/Resume

func togglePause() {
    if state.isPaused {
        debugPrint("RESUME — sending SIGCONT")
        try? FileManager.default.removeItem(atPath: pauseFlag)
        showTTYSubtitle("▶ resumed")

        for name in ["afplay", "say", "whisper-stream"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-CONT", name]
            try? proc.run()
            proc.waitUntilExit()
        }
        state.isPaused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { playChime() }
    } else {
        debugPrint("PAUSE — sending SIGSTOP")
        FileManager.default.createFile(atPath: pauseFlag, contents: nil)
        showTTYSubtitle("⏸ paused")

        for name in ["afplay", "say", "whisper-stream"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-STOP", name]
            try? proc.run()
            proc.waitUntilExit()
        }
        state.isPaused = true
        playChime()
    }
}

// MARK: - Skip

func triggerSkip() {
    debugPrint("SKIP — killing audio, creating skip flag")
    let preservePause = FileManager.default.fileExists(atPath: pauseFlag) || state.isPaused

    // If paused, resume first so processes can be killed cleanly
    if state.isPaused {
        for name in ["afplay", "say", "whisper-stream"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-CONT", name]
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    if !preservePause {
        try? FileManager.default.removeItem(atPath: pauseFlag)
        state.isPaused = false
    } else {
        FileManager.default.createFile(atPath: pauseFlag, contents: nil)
        state.isPaused = true
    }

    killTTSProcesses()
    playChime()

    debugPrint("Killed say + afplay, created skip flag")
}

// MARK: - Stop All (shift+shift)

func triggerStopAll() {
    debugPrint("STOP ALL — killing everything")
    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    try? FileManager.default.removeItem(atPath: pauseFlag)
    state.isPaused = false

    // Kill file read if active — clear flag so auto-speak resumes
    let wasReadingFile = isReadingFile()
    if wasReadingFile {
        try? FileManager.default.removeItem(atPath: readingFileFlag)
        // Kill read-file.sh process
        let killRead = Process()
        killRead.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killRead.arguments = ["-f", "read-file.sh"]
        try? killRead.run()
        killRead.waitUntilExit()
        debugPrint("STOP ALL — killed active file read")
    }

    for name in ["say", "afplay", "voice-input", "whisper-stream"] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", name]
        try? proc.run()
        proc.waitUntilExit()
    }
    try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
    try? FileManager.default.removeItem(atPath: micListeningFlag)

    // Force-release TTS lock in case something is stuck
    try? FileManager.default.removeItem(atPath: ttsLockDir)
    clearActiveSegment()

    // Reset repeat anchor — next repeat plays from latest terminal message,
    // NOT from where the file read or TTS was killed
    resetRepeatAnchor()

    clearTTYSubtitle()

    // Chime AFTER cleanup so pkill doesn't kill it
    usleep(100_000)
    playChime()
    debugPrint("STOP ALL — everything killed, lock cleared, anchor reset to last terminal message")
}

// MARK: - Repeat (cmd+shift)

// Read all messages from session history directory starting from a given index
func readHistoryMessages(from startIndex: Int) -> [(text: String, speed: String, volume: String)] {
    guard let histDir = try? String(contentsOfFile: historyDirFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) else {
        debugPrint("REPEAT — no history dir file")
        return []
    }
    guard let totalStr = try? String(contentsOfFile: "\(histDir)/total", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          let total = Int(totalStr), total > 0 else {
        debugPrint("REPEAT — no history total")
        return []
    }

    var messages: [(text: String, speed: String, volume: String)] = []
    for i in startIndex...total {
        let padded = String(format: "%03d", i)
        guard let text = try? String(contentsOfFile: "\(histDir)/msg-\(padded).txt", encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        let speed = (try? String(contentsOfFile: "\(histDir)/msg-\(padded).speed", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "300"
        let volume = (try? String(contentsOfFile: "\(histDir)/msg-\(padded).volume", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "1.0"
        messages.append((text: text, speed: speed, volume: volume))
    }
    return messages
}

func readHistoryMessage(at index: Int) -> PlaybackContext? {
    guard index > 0 else { return nil }
    guard let histDir = try? String(contentsOfFile: historyDirFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !histDir.isEmpty else {
        return nil
    }

    let padded = String(format: "%03d", index)
    guard let text = try? String(contentsOfFile: "\(histDir)/msg-\(padded).txt", encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

    let speed = (try? String(contentsOfFile: "\(histDir)/msg-\(padded).speed", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "300"
    let volume = (try? String(contentsOfFile: "\(histDir)/msg-\(padded).volume", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "1.0"
    let sourceLabel = normalizeSourceLabel(try? String(contentsOfFile: "\(histDir)/msg-\(padded).source", encoding: .utf8))

    return (text: text, speed: speed, volume: volume, sourceLabel: sourceLabel, sessionID: nil)
}

func historyMessageTotal() -> Int {
    guard let histDir = try? String(contentsOfFile: historyDirFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !histDir.isEmpty,
          let totalStr = try? String(contentsOfFile: "\(histDir)/total", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
          let total = Int(totalStr), total > 0 else {
        return 0
    }

    return total
}

// Get the repeat anchor index — where repeat should start from
func getRepeatAnchor() -> Int {
    if let anchorStr = try? String(contentsOfFile: repeatAnchorFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       let anchor = Int(anchorStr), anchor > 0 {
        return anchor
    }
    // Fallback: start from message 1
    return 1
}

// Reset repeat anchor to the very last message in history
func resetRepeatAnchor() {
    guard let histDir = try? String(contentsOfFile: historyDirFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
    guard let totalStr = try? String(contentsOfFile: "\(histDir)/total", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          let total = Int(totalStr), total > 0 else { return }

    // Shift+Shift resets to the physical last message — not the block start
    try? "\(total)".write(toFile: repeatAnchorFile, atomically: true, encoding: .utf8)
    debugPrint("RESET ANCHOR — set to last message \(total)")
}

func loadReplayContext() -> PlaybackContext? {
    let anchor = getRepeatAnchor()
    if let historyMessage = readHistoryMessage(at: anchor) {
        return historyMessage
    }

    guard let text = try? String(contentsOfFile: lastTextFile, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

    let speed = (try? String(contentsOfFile: lastSpeedFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "300"
    let volume = (try? String(contentsOfFile: lastVolumeFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "1.0"
    let sourceLabel = normalizeSourceLabel(try? String(contentsOfFile: lastSourceFile, encoding: .utf8))
    let sessionID = normalizeSessionID(try? String(contentsOfFile: lastSessionFile, encoding: .utf8))

    return (text: text, speed: speed, volume: volume, sourceLabel: sourceLabel, sessionID: sessionID)
}

func playContext(_ context: PlaybackContext, startIndex: Int, status: String) {
    let sentences = splitSentences(context.text)
    guard !sentences.isEmpty else {
        debugPrint("PLAYBACK — no sentences available for \(status)")
        playChime()
        return
    }

    let clampedStart = min(max(startIndex, 0), max(sentences.count - 1, 0))

    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    killTTSProcesses()

    DispatchQueue.global(qos: .userInitiated).async {
        usleep(300_000)
        playChime()

        acquireTTSLock()
        try? FileManager.default.removeItem(atPath: skipFlag)

        try? context.text.write(toFile: lastTextFile, atomically: true, encoding: .utf8)
        try? context.speed.write(toFile: lastSpeedFile, atomically: true, encoding: .utf8)
        try? context.volume.write(toFile: lastVolumeFile, atomically: true, encoding: .utf8)
        if let source = context.sourceLabel {
            try? source.write(toFile: lastSourceFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: lastSourceFile)
        }
        if let session = context.sessionID {
            try? session.write(toFile: lastSessionFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: lastSessionFile)
        }

        writePlaybackCursor(clampedStart)
        FileManager.default.createFile(atPath: ttsPlayingFlag, contents: nil)
        writeActiveSegment(preview: playbackPreview(context), status: status)

        speakText(
            context.text,
            speed: context.speed,
            volume: context.volume,
            sourceLabel: context.sourceLabel,
            sessionID: context.sessionID,
            startIndex: clampedStart
        )

        clearTTYSubtitle()
        try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
        try? FileManager.default.removeItem(atPath: skipFlag)
        clearActiveSegment()
        releaseTTSLock()
    }
}

func triggerSentenceSeek(delta: Int) {
    guard let context = loadReplayContext() else {
        debugPrint("SEEK — no replay context")
        playChime()
        return
    }

    let sentences = splitSentences(context.text)
    guard !sentences.isEmpty else {
        debugPrint("SEEK — replay context has no sentences")
        playChime()
        return
    }

    let currentCursor = min(max(readPlaybackCursor(), 0), sentences.count)
    let target: Int

    if delta > 0 {
        guard currentCursor < sentences.count else {
            debugPrint("SEEK — already at end of message")
            playChime()
            return
        }
        target = min(currentCursor + delta, max(sentences.count - 1, 0))
    } else {
        let rewindBase = currentCursor >= sentences.count ? max(sentences.count - 1, 0) : currentCursor
        target = max(rewindBase + delta, 0)
        if target == rewindBase && rewindBase == 0 {
            debugPrint("SEEK — already at start of message")
            playChime()
            return
        }
    }

    debugPrint("SEEK — replaying from sentence \(target + 1)/\(sentences.count)")
    playContext(context, startIndex: target, status: "seek")
}

func triggerRepeat() {
    debugPrint("REPEAT — replaying current message from start")

    guard let context = loadReplayContext() else {
        debugPrint("REPEAT — no saved text at all, ignoring")
        playChime()
        return
    }

    playContext(context, startIndex: 0, status: "repeat")
}

// Shared text-to-speech function — speaks sentence by sentence with skip/forward/rewind support
func speakText(_ text: String, speed: String, volume: String, sourceLabel: String? = nil, sessionID: String? = nil, startIndex: Int = 0) {
    let sentences = splitSentences(text)
    guard !sentences.isEmpty else { return }

    let normalizedSource = normalizeSourceLabel(sourceLabel)
    let normalizedSession = normalizeSessionID(sessionID)
    let lastSpokenSource = normalizeSourceLabel(try? String(contentsOfFile: lastSourceFile, encoding: .utf8))
    let lastSpokenSession = normalizeSessionID(try? String(contentsOfFile: lastSessionFile, encoding: .utf8))
    let shouldAnnounceSource =
        normalizedSource != nil &&
        (normalizedSource != lastSpokenSource || normalizedSession != nil && normalizedSession != lastSpokenSession)

    var idx = min(max(startIndex, 0), max(sentences.count - 1, 0))
    while idx < sentences.count {
        if FileManager.default.fileExists(atPath: skipFlag) { break }
        if !waitWhilePaused() { break }

        // Check forward/rewind
        if FileManager.default.fileExists(atPath: forwardFlag) {
            try? FileManager.default.removeItem(atPath: forwardFlag)
            killTTSProcesses()
            idx = min(idx + 1, sentences.count - 1)
            continue
        }
        if FileManager.default.fileExists(atPath: rewindFlag) {
            try? FileManager.default.removeItem(atPath: rewindFlag)
            killTTSProcesses()
            idx = max(idx - 1, 0)
            continue
        }

        let sentence = sentences[idx]
        let subtitleText: String
        let spokenText: String

        if let source = normalizedSource {
            subtitleText = "[\(source)] \(sentence)"
            if idx == 0 && shouldAnnounceSource {
                spokenText = "\(source). \(sentence)"
            } else {
                spokenText = sentence
            }
        } else {
            subtitleText = sentence
            spokenText = sentence
        }

        let tmpFile = "/tmp/claude-tts-repeat-\(ProcessInfo.processInfo.processIdentifier).aiff"

        showTTYSubtitle(subtitleText)
        writePlaybackCursor(idx)

        // Generate audio
        let synthesized = synthesizeSpeechAudio(spokenText, speed: speed, outputFile: tmpFile)
        if !synthesized {
            debugPrint("TTS — say synthesis failed for sentence \(idx + 1)")
            try? FileManager.default.removeItem(atPath: tmpFile)
            idx += 1
            continue
        }

        if FileManager.default.fileExists(atPath: skipFlag) {
            try? FileManager.default.removeItem(atPath: tmpFile)
            break
        }
        if !waitWhilePaused() {
            try? FileManager.default.removeItem(atPath: tmpFile)
            break
        }

        // Play audio
        let played = playAudioFile(tmpFile, volume: volume)

        try? FileManager.default.removeItem(atPath: tmpFile)
        if !played {
            debugPrint("TTS — afplay failed for sentence \(idx + 1)")
            idx += 1
            continue
        }
        if FileManager.default.fileExists(atPath: skipFlag) { break }
        if FileManager.default.fileExists(atPath: forwardFlag) || FileManager.default.fileExists(atPath: rewindFlag) {
            continue
        }
        if idx == 0, let source = normalizedSource {
            try? source.write(toFile: lastSourceFile, atomically: true, encoding: .utf8)
        }
        if idx == 0 {
            if let session = normalizedSession {
                try? session.write(toFile: lastSessionFile, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(atPath: lastSessionFile)
            }
        }
        writePlaybackCursor(idx + 1)
        idx += 1
    }
}

func adjustSpeechSpeed(delta: Int) {
    let current = Int(currentSpeechSpeed()) ?? 300
    let updated = min(max(current + delta, minSpeechSpeed), maxSpeechSpeed)
    if updated == current {
        playChime()
        debugPrint("SPEED — already at limit \(current)")
        return
    }

    writeConfigValue("speed", value: "\(updated)")
    try? "\(updated)".write(toFile: lastSpeedFile, atomically: true, encoding: .utf8)
    debugPrint("SPEED — updated from \(current) to \(updated)")
    showTTYSubtitle("speed \(updated)")
    playChime()
}

// MARK: - Drill-Down (opt+shift double-tap or voice keyword)

func triggerDrillDown(target: String? = nil) {
    debugPrint("DRILL-DOWN — target: \(target ?? "cycle")")

    // Read available cache entries from index
    guard let indexContent = try? String(contentsOfFile: detailIndexFile, encoding: .utf8) else {
        debugPrint("DRILL-DOWN — no index file, ignoring")
        playChime()
        return
    }

    let entries = indexContent.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !entries.isEmpty else {
        debugPrint("DRILL-DOWN — index empty, ignoring")
        playChime()
        return
    }

    // Determine which entry to play
    var entryFile: String
    if let t = target {
        if t == "all" {
            // Play all entries sequentially — use first for now, loop handled below
            entryFile = entries[0]
        } else {
            // Find first entry matching target keyword (table/list/etc.)
            if let match = entries.first(where: { $0.lowercased().contains(t.lowercased()) }) {
                entryFile = match
            } else {
                debugPrint("DRILL-DOWN — no entry matching '\(t)', ignoring")
                playChime()
                return
            }
        }
    } else {
        // Cycle mode — read current drill index, advance
        let currentStr = (try? String(contentsOfFile: drillDownIndexFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "-1"
        var current = Int(currentStr) ?? -1
        current = (current + 1) % entries.count
        try? "\(current)".write(toFile: drillDownIndexFile, atomically: true, encoding: .utf8)
        entryFile = entries[current]
        debugPrint("DRILL-DOWN — cycling to entry \(current + 1)/\(entries.count): \(entryFile)")
    }

    // Stop any active audio
    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    killTTSProcesses()
    usleep(300_000)

    acquireTTSLock()
    try? FileManager.default.removeItem(atPath: skipFlag)

    // Read speed/volume from voice config
    let speed = currentSpeechSpeed()
    let volLine = readConfigValue("volume").isEmpty ? "normal" : readConfigValue("volume")
    let volume = volLine == "quiet" ? "0.3" : "1.0"

    // Determine entries to play
    let entriesToPlay: [String]
    if let t = target, t == "all" {
        entriesToPlay = entries
    } else {
        entriesToPlay = [entryFile]
    }

    // Mark TTS as playing and chime
    FileManager.default.createFile(atPath: ttsPlayingFlag, contents: nil)
    let previewText = String((try? String(contentsOfFile: "\(detailCacheDir)/\(entriesToPlay[0])", encoding: .utf8))?.prefix(60) ?? "")
    writeActiveSegment(preview: previewText, status: "drill-down")
    playDoubleTink()

    // Play in background
    DispatchQueue.global(qos: .userInitiated).async {
        for entry in entriesToPlay {
            let filePath = "\(detailCacheDir)/\(entry)"
            guard let text = try? String(contentsOfFile: filePath, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                debugPrint("DRILL-DOWN — empty or missing file: \(filePath)")
                continue
            }

            // Save for repeat
            try? text.write(toFile: lastTextFile, atomically: true, encoding: .utf8)
            try? speed.write(toFile: lastSpeedFile, atomically: true, encoding: .utf8)
            try? volume.write(toFile: lastVolumeFile, atomically: true, encoding: .utf8)

            let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var skipped = false
            var idx = 0
            while idx < sentences.count {
                if FileManager.default.fileExists(atPath: skipFlag) { skipped = true; break }

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
                let tmpFile = "/tmp/claude-tts-drill-\(ProcessInfo.processInfo.processIdentifier).aiff"

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
                    skipped = true
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

            if skipped { break }
        }

        // Cleanup
        try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
        try? FileManager.default.removeItem(atPath: skipFlag)
        clearActiveSegment()
        releaseTTSLock()
    }
}

// MARK: - Message Navigation (opt+shift+arrow)

func extractAssistantTextBlocks(from message: [String: Any]) -> [String] {
    if let role = message["role"] as? String, role != "assistant" {
        return []
    }

    guard let content = message["content"] as? [[String: Any]] else {
        return []
    }

    var blocks: [String] = []
    for block in content {
        let blockType = (block["type"] as? String) ?? ""
        guard blockType == "text" || blockType == "output_text" || blockType == "input_text",
              let text = block["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continue
        }
        blocks.append(text)
    }

    return blocks
}

func appendTranscriptMessages(from obj: [String: Any], to messages: inout [String]) {
    if obj["type"] as? String == "assistant",
       let message = obj["message"] as? [String: Any] {
        messages.append(contentsOf: extractAssistantTextBlocks(from: message))
    }

    if obj["type"] as? String == "response_item",
       let payload = obj["payload"] as? [String: Any],
       payload["type"] as? String == "message",
       payload["role"] as? String == "assistant" {
        messages.append(contentsOf: extractAssistantTextBlocks(from: payload))
    }
}

// Extract assistant text blocks from transcript JSONL — supports both legacy and
// payload-wrapped transcript formats.
func extractMessagesFromTranscript() -> [String] {
    guard let tPath = try? String(contentsOfFile: transcriptPathFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          let data = FileManager.default.contents(atPath: tPath) else {
        debugPrint("MESSAGE NAV — no transcript file")
        return []
    }

    var messages: [String] = []
    // Parse line by line from raw data to avoid loading entire string
    data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
        guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let len = rawBuffer.count
        var start = 0
        for i in 0..<len {
            if base[i] == 0x0A || i == len - 1 { // newline or EOF
                let end = (i == len - 1 && base[i] != 0x0A) ? i + 1 : i
                if end > start {
                    let lineData = Data(bytes: base + start, count: end - start)
                    if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        appendTranscriptMessages(from: obj, to: &messages)
                    }
                }
                start = i + 1
            }
        }
    }
    return messages
}

func triggerMessageNav(direction: String) {
    debugPrint("MESSAGE NAV — \(direction)")

    // Signal auto-speak.sh to stop and kill audio
    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    killTTSProcesses()
    try? FileManager.default.removeItem(atPath: ttsPlayingFlag)

    // Everything on background thread — main thread must stay free for CGEvent
    DispatchQueue.global(qos: .userInitiated).async {
        // Wait for the speaking session to release the lock (up to 3s timeout)
        var waited = 0
        while FileManager.default.fileExists(atPath: ttsLockDir) && waited < 30 {
            // Check if lock holder is dead
            if let pidStr = try? String(contentsOfFile: ttsLockPidFile, encoding: .utf8),
               let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if kill(pid, 0) != 0 {
                    // Dead process — clear stale lock
                    try? FileManager.default.removeItem(atPath: ttsLockDir)
                    break
                }
            }
            usleep(100_000)
            waited += 1
        }
        // Force-clear if we timed out
        if FileManager.default.fileExists(atPath: ttsLockDir) {
            try? FileManager.default.removeItem(atPath: ttsLockDir)
        }

        // Chime immediately — audio is dead
        playChime()
        // Brief wait then kill any straggler say processes (not afplay so chime survives)
        usleep(200_000)
        let killSay = Process()
        killSay.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killSay.arguments = ["say"]
        try? killSay.run()
        killSay.waitUntilExit()
        try? FileManager.default.removeItem(atPath: skipFlag)
        let totalHistory = historyMessageTotal()
        if totalHistory > 0 {
            debugPrint("MESSAGE NAV — using session history (\(totalHistory) messages)")

            let defaultIndex = min(max(getRepeatAnchor() - 1, 0), totalHistory - 1)
            let currentStr = (try? String(contentsOfFile: navIndexFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "\(defaultIndex)"
            var current = Int(currentStr) ?? defaultIndex
            current = min(max(current, 0), totalHistory - 1)

            if direction == "next" {
                guard current < totalHistory - 1 else { playChime(); return }
                current += 1
            } else {
                guard current > 0 else { playChime(); return }
                current -= 1
            }

            let historyIndex = current + 1
            guard let context = readHistoryMessage(at: historyIndex) else {
                debugPrint("MESSAGE NAV — missing history message \(historyIndex)")
                playChime()
                return
            }

            try? "\(current)".write(toFile: navIndexFile, atomically: true, encoding: .utf8)
            try? "\(historyIndex)".write(toFile: repeatAnchorFile, atomically: true, encoding: .utf8)
            debugPrint("MESSAGE NAV — updated repeat anchor to \(historyIndex)")
            debugPrint("MESSAGE NAV — playing history \(historyIndex)/\(totalHistory)")

            playContext(context, startIndex: 0, status: "nav")
            return
        }

        debugPrint("MESSAGE NAV — no session history, falling back to transcript")
        let messages = extractMessagesFromTranscript()
        let total = messages.count
        debugPrint("MESSAGE NAV — found \(total) transcript messages")

        guard total > 0 else {
            debugPrint("MESSAGE NAV — no transcript messages, playing boundary chime")
            playChime()
            return
        }

        let currentStr = (try? String(contentsOfFile: navIndexFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "\(total - 1)"
        var current = Int(currentStr) ?? (total - 1)
        current = min(max(current, 0), total - 1)

        if direction == "next" {
            guard current < total - 1 else { playChime(); return }
            current += 1
        } else {
            guard current > 0 else { playChime(); return }
            current -= 1
        }

        try? "\(current)".write(toFile: navIndexFile, atomically: true, encoding: .utf8)
        let context: PlaybackContext = (
            text: messages[current],
            speed: currentSpeechSpeed(),
            volume: "1.0",
            sourceLabel: nil,
            sessionID: nil
        )
        debugPrint("MESSAGE NAV — playing transcript \(current + 1)/\(total)")
        playContext(context, startIndex: 0, status: "nav")
    }
}

// MARK: - Queue Processing (daemon speaks queued messages from auto-speak.sh)

func processQueue() {
    guard !state.isProcessingQueue else { return }
    state.isProcessingQueue = true

    DispatchQueue.global(qos: .userInitiated).async {
        defer { state.isProcessingQueue = false }

        let fm = FileManager.default
        guard fm.fileExists(atPath: queueDir) else { return }

        // List queue entries sorted by name (timestamp-based, so chronological)
        guard let entries = try? fm.contentsOfDirectory(atPath: queueDir).sorted() else { return }
        let queueEntries = entries.filter { $0.hasPrefix("entry-") }

        guard !queueEntries.isEmpty else { return }
        debugPrint("QUEUE — found \(queueEntries.count) entries to speak")

        acquireTTSLock()
        fm.createFile(atPath: ttsPlayingFlag, contents: nil)

        for (idx, entry) in queueEntries.enumerated() {
            let entryPath = "\(queueDir)/\(entry)"

            // Check skip flag — if set, clear remaining queue
            if fm.fileExists(atPath: skipFlag) {
                debugPrint("QUEUE — skip flag detected, clearing remaining entries")
                // Remove this and all remaining entries
                for remaining in queueEntries[idx...] {
                    try? fm.removeItem(atPath: "\(queueDir)/\(remaining)")
                }
                try? fm.removeItem(atPath: skipFlag)
                break
            }

            // Read entry files
            guard let text = try? String(contentsOfFile: "\(entryPath)/text", encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try? fm.removeItem(atPath: entryPath)
                continue
            }

            let speed = (try? String(contentsOfFile: "\(entryPath)/speed", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "300"
            let volume = (try? String(contentsOfFile: "\(entryPath)/volume", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "1.0"
            let sourceLabel = normalizeSourceLabel(try? String(contentsOfFile: "\(entryPath)/source", encoding: .utf8))
            let sessionID = normalizeSessionID(try? String(contentsOfFile: "\(entryPath)/session", encoding: .utf8))
            let effectiveSpeed = currentSpeechSpeed(fallback: speed)
            let previewBase = String(text.prefix(60))
            let previewText = sourceLabel != nil ? "[\(sourceLabel!)] \(previewBase)" : previewBase
            writeActiveSegment(segment: idx + 1, total: queueEntries.count,
                             preview: previewText, status: "speaking")
            debugPrint("QUEUE — speaking entry \(idx + 1)/\(queueEntries.count)")

            try? effectiveSpeed.write(toFile: lastSpeedFile, atomically: true, encoding: .utf8)
            speakText(text, speed: effectiveSpeed, volume: volume, sourceLabel: sourceLabel, sessionID: sessionID)

            // Remove processed entry
            try? fm.removeItem(atPath: entryPath)
        }

        // Cleanup
        clearTTYSubtitle()
        try? fm.removeItem(atPath: ttsPlayingFlag)
        try? fm.removeItem(atPath: skipFlag)
        clearActiveSegment()
        releaseTTSLock()
        debugPrint("QUEUE — done processing")
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

    // Stay resident under launchd, but ignore shortcut handling while voice mode
    // is off unless playback/mic activity is still cleaning up.
    if !hasVoiceConfig() && !isVoiceActive() {
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
        let isArrowKey = (keyCode == leftArrowKeyCode || keyCode == rightArrowKeyCode || keyCode == upArrowKeyCode || keyCode == downArrowKeyCode)
        if isArrowKey {
            let hasOption = flags.contains(.maskAlternate)
            let hasShift = flags.contains(.maskShift)
            let hasCommand = flags.contains(.maskCommand)
            let hasControl = flags.contains(.maskControl)

            if hasOption && !hasShift && !hasCommand && !hasControl && (keyCode == upArrowKeyCode || keyCode == downArrowKeyCode) {
                markOptionComboUse()
                if keyCode == upArrowKeyCode {
                    debugPrint("OPT+UP — increase speed")
                    DispatchQueue.main.async { adjustSpeechSpeed(delta: speechSpeedStep) }
                } else {
                    debugPrint("OPT+DOWN — decrease speed")
                    DispatchQueue.main.async { adjustSpeechSpeed(delta: -speechSpeedStep) }
                }
                return Unmanaged.passUnretained(event)
            }

            // opt+shift+arrow: during file read = 20-line skip, otherwise = message nav
            if hasOption && hasShift && !hasCommand && !hasControl && (keyCode == leftArrowKeyCode || keyCode == rightArrowKeyCode) {
                markOptionComboUse()
                if isReadingFile() {
                    // File read active — skip 20 lines forward/back
                    if keyCode == rightArrowKeyCode {
                        debugPrint("OPT+SHIFT+RIGHT — big forward 20 lines (file read)")
                        FileManager.default.createFile(atPath: bigForwardFlag, contents: nil)
                    } else {
                        debugPrint("OPT+SHIFT+LEFT — big rewind 20 lines (file read)")
                        FileManager.default.createFile(atPath: bigRewindFlag, contents: nil)
                    }
                    killTTSProcesses()
                    usleep(100_000)
                    playChime()
                } else {
                    // Terminal mode — message navigation
                    let direction = (keyCode == rightArrowKeyCode) ? "next" : "prev"
                    debugPrint("OPT+SHIFT+ARROW — message nav \(direction)")
                    DispatchQueue.main.async { triggerMessageNav(direction: direction) }
                }
                return Unmanaged.passUnretained(event)
            }

            // opt+arrow: forward/rewind. While speaking, seek within the active playback.
            // When idle, replay the last message from a new sentence offset.
            if hasOption && !hasShift && !hasCommand && !hasControl && (keyCode == leftArrowKeyCode || keyCode == rightArrowKeyCode) {
                markOptionComboUse()
                if keyCode == rightArrowKeyCode {
                    if isTTSPlaying() {
                        debugPrint("OPT+RIGHT — forward 1 sentence")
                        FileManager.default.createFile(atPath: forwardFlag, contents: nil)
                        killTTSProcesses()
                        usleep(100_000)
                        playChime()
                    } else {
                        debugPrint("OPT+RIGHT — replay forward 1 sentence from saved message")
                        DispatchQueue.main.async { triggerSentenceSeek(delta: 1) }
                    }
                } else {
                    if isTTSPlaying() {
                        debugPrint("OPT+LEFT — rewind 1 sentence")
                        FileManager.default.createFile(atPath: rewindFlag, contents: nil)
                        killTTSProcesses()
                        usleep(100_000)
                        playChime()
                    } else {
                        debugPrint("OPT+LEFT — replay backward 1 sentence from saved message")
                        DispatchQueue.main.async { triggerSentenceSeek(delta: -1) }
                    }
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

    // --- OPT+SHIFT DOUBLE-TAP: DRILL-DOWN ---
    // Detect opt+shift held together then released twice. Does NOT interfere
    // with opt+shift+arrow (that's a keyDown event, this is flagsChanged).
    if isOptionKey || isShiftKey {
        let hasOption = flags.contains(.maskAlternate)
        let hasShift = flags.contains(.maskShift)
        let hasCommand = flags.contains(.maskCommand)
        let hasControl = flags.contains(.maskControl)

        // When both opt+shift are pressed (and no cmd/ctrl)
        if hasOption && hasShift && !hasCommand && !hasControl {
            if !state.optShiftTriggered {
                state.optShiftTriggered = true
                debugPrint("OPT+SHIFT down — armed for drill-down")
            }
        }

        // When all modifiers released (keys release one at a time, so this fires
        // on the SECOND release — e.g., opt releases, then shift releases)
        if state.optShiftTriggered && !hasOption && !hasShift && !hasCommand && !hasControl {
            state.optShiftTriggered = false
            let now = Date()
            state.lastOptionComboUse = now

            if let last = state.lastOptShiftUp, now.timeIntervalSince(last) < doubleTapWindow {
                state.lastOptShiftUp = nil
                debugPrint("OPT+SHIFT DOUBLE TAP — triggering drill-down")
                playChime()
                DispatchQueue.main.async { triggerDrillDown() }
            } else {
                state.lastOptShiftUp = now
            }
        }

        // If one released while other held, keep armed — don't disarm.
        // The "all released" check above handles the full release.
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

            if let lastCombo = state.lastOptionComboUse, now.timeIntervalSince(lastCombo) < doubleTapWindow {
                debugPrint("OPTION DOUBLE TAP — suppressed after option-based combo")
                state.lastOptionUp = nil
                return Unmanaged.passUnretained(event)
            }

            if let last = state.lastOptionUp, now.timeIntervalSince(last) < doubleTapWindow {
                state.lastOptionUp = nil
                // Always allow pause toggle — if user double-taps opt, they want to pause/resume.
                // Checking isVoiceActive() was too strict: the flag can be cleared between sentences.
                debugPrint("OPTION DOUBLE TAP — toggling pause")
                DispatchQueue.main.async { togglePause() }
            } else {
                state.lastOptionUp = now
            }
        }
    }

    // --- SHIFT DOUBLE-TAP: STOP ALL ---
    if isShiftKey {
        let hasShift = flags.contains(.maskShift)

        // Only trigger when shift alone (no cmd, opt, ctrl)
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            state.shiftIsDown = false
            state.lastShiftUp = nil
            return Unmanaged.passUnretained(event)
        }

        // Don't trigger if cmd+shift repeat or opt+shift drill-down is armed
        if state.cmdShiftTriggered || state.optShiftTriggered {
            return Unmanaged.passUnretained(event)
        }

        if hasShift && !state.shiftIsDown {
            state.shiftIsDown = true
        } else if !hasShift && state.shiftIsDown {
            state.shiftIsDown = false
            let now = Date()

            if let last = state.lastShiftUp, now.timeIntervalSince(last) < doubleTapWindow {
                state.lastShiftUp = nil
                debugPrint("SHIFT DOUBLE TAP — stop all")
                DispatchQueue.main.async { triggerStopAll() }
            } else {
                state.lastShiftUp = now
            }
        }
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - Permission Check

let trusted = AXIsProcessTrusted()
debugPrint("AXIsProcessTrusted: \(trusted)")

let listenGranted = CGPreflightListenEventAccess()
debugPrint("CGPreflightListenEventAccess: \(listenGranted)")

let permissionTarget = permissionTargetPath()

if doctorMode {
    runDoctor()
}

if !trusted {
    // Prompt the user to grant Accessibility permission
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    let _ = AXIsProcessTrustedWithOptions(options)
    fputs("⚠ Accessibility permission not granted. A system dialog should appear.\n", stderr)
    fputs("  Add this app: \(permissionTarget)\n", stderr)
    fputs("  System Settings > Privacy & Security > Accessibility\n", stderr)
    debugPrint("Accessibility not granted — prompted user")
    // Continue anyway — the tap may still create but not receive events
}

if !listenGranted {
    let requested = CGRequestListenEventAccess()
    fputs("⚠ Input Monitoring permission not granted.\n", stderr)
    fputs("  Add this app: \(permissionTarget)\n", stderr)
    fputs("  System Settings > Privacy & Security > Input Monitoring\n", stderr)
    debugPrint("Input Monitoring not granted — requested access, returned=\(requested)")
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
    let msg = "Error: Could not create event tap."
    fputs("\(msg)\n", stderr)
    fputs("  Grant BOTH permissions to: \(permissionTarget)\n", stderr)
    fputs("  1. System Settings > Privacy & Security > Accessibility\n", stderr)
    fputs("  2. System Settings > Privacy & Security > Input Monitoring\n", stderr)
    debugPrint("FATAL: \(msg)")
    exit(1)
}

globalTap = tap
let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

let tapEnabled = CGEvent.tapIsEnabled(tap: tap)
debugPrint("Event tap created (listenOnly), enabled=\(tapEnabled), listening for all voice controls")

// MARK: - Self-Test (verify events actually flow)

var selfTestPassed = false

// Post a synthetic flagsChanged event and check if the callback receives it
let selfTestBefore = state.lastCommandUp  // snapshot state before test

if let source = CGEventSource(stateID: .hidSystemState) {
    // Synthesize a left-shift keyDown then keyUp (harmless modifier)
    if let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true),
       let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) {
        // Post as flagsChanged with shift flag
        shiftDown.type = .flagsChanged
        shiftDown.flags = .maskShift
        shiftDown.post(tap: .cgSessionEventTap)

        shiftUp.type = .flagsChanged
        shiftUp.flags = []
        shiftUp.post(tap: .cgSessionEventTap)

        debugPrint("Self-test: posted synthetic shift events")
    }
}

// Check after a short delay if the callback was invoked
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    // The callback doesn't track shift specifically, but the tap-disabled handler
    // would have fired if the tap was disabled. Check the debug log for evidence.
    // We check tapIsEnabled as a proxy — if macOS silently disabled the tap, it'll be false.
    if let t = globalTap {
        let stillEnabled = CGEvent.tapIsEnabled(tap: t)
        debugPrint("Self-test result: tap still enabled=\(stillEnabled)")
        if !stillEnabled {
            fputs("⚠ Event tap was disabled by macOS. Events will NOT be received.\n", stderr)
            fputs("  Add this binary to BOTH:\n", stderr)
            fputs("  1. System Settings > Privacy & Security > Accessibility\n", stderr)
            fputs("  2. System Settings > Privacy & Security > Input Monitoring\n", stderr)
            fputs("  App: \(permissionTarget)\n", stderr)
            debugPrint("SELF-TEST FAILED: tap disabled by OS")
            // Re-enable and keep trying — permission might be granted while running
            CGEvent.tapEnable(tap: t, enable: true)
        }
    }
}

// MARK: - Config File Poll (daemon keepalive)

var configMissCount = 0
var configCheckCounter = 0  // Only check config every 6th tick (6 * 0.3s ≈ 2s)

let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
    // Queue check runs every tick (0.3s) for responsive pickup
    if FileManager.default.fileExists(atPath: queueDir) && !state.isProcessingQueue {
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: queueDir),
           entries.contains(where: { $0.hasPrefix("entry-") }) {
            processQueue()
        }
    }

    configCheckCounter += 1
    guard configCheckCounter >= 6 else { return }
    configCheckCounter = 0

    // Original 2-second checks below
    if FileManager.default.fileExists(atPath: configFile) {
        configMissCount = 0

        // Check drill-down flag (set by voice-input keyword detection)
        if FileManager.default.fileExists(atPath: drillDownFlag) {
            if let target = try? String(contentsOfFile: drillDownFlag, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) {
                try? FileManager.default.removeItem(atPath: drillDownFlag)
                debugPrint("DRILL-DOWN FLAG — target: \(target)")
                DispatchQueue.main.async { triggerDrillDown(target: target.isEmpty ? nil : target) }
            }
        }

        // Update status line when TTS is active
        if FileManager.default.fileExists(atPath: ttsPlayingFlag) {
            updateStatusLine()
        } else {
            clearStatusLine()
        }
    } else {
        if configMissCount < 3 {
            configMissCount += 1
            debugPrint("Config file missing (count: \(configMissCount)/3)")
        }

        if configMissCount == 3 {
            debugPrint("Config file gone for 6s — entering idle mode until voice mode returns")
            clearStatusLine()
        }
    }
}

RunLoop.current.add(timer, forMode: .common)
CFRunLoopRun()
