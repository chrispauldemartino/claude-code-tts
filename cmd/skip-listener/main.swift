import Foundation
import CoreGraphics
import ApplicationServices

// Monitors modifier keys and key combos for voice mode controls:
// - Double-Command tap (cmd+cmd): SKIP — kills audio + mic
// - Double-Option tap (opt+opt): PAUSE/RESUME — SIGSTOP/SIGCONT
// - Command+Shift (single tap): REPEAT — replay last TTS response
// - Option+Arrow (keyDown): FORWARD/REWIND — skip ±3 sentences
// - Option+Shift+Arrow (keyDown): MESSAGE NAV — play prev/next history message
// - Enter (keyDown): STOP — kills entire voice session
//
// Usage: skip-listener [--debug]
// Runs as persistent daemon. Exits when /tmp/claude-voice-config is removed.
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
let sendingFlag = "/tmp/claude-voice-input-sending"
let voiceInputStopFlag = "/tmp/claude-voice-input-stop"

// Repeat state files
let lastTextFile = "/tmp/claude-tts-last-text"
let lastSpeedFile = "/tmp/claude-tts-last-speed"
let lastVolumeFile = "/tmp/claude-tts-last-volume"

// Forward/rewind flags
let forwardFlag = "/tmp/claude-tts-forward"
let rewindFlag = "/tmp/claude-tts-rewind"

// Message navigation — reads from transcript JSONL
let transcriptPathFile = "/tmp/claude-tts-transcript-path"
let navIndexFile = "/tmp/claude-tts-nav-index"

// Drill-down cache for structured data (tables/lists)
let detailCacheDir = "/tmp/claude-tts-detail-cache"
let detailIndexFile = "/tmp/claude-tts-detail-cache/index.txt"
let drillDownFlag = "/tmp/claude-tts-drill-down"
let drillDownIndexFile = "/tmp/claude-tts-detail-cache/drill-index"
let activeSegmentFile = "/tmp/claude-tts-active-segment"

// MARK: - Arguments

var debug = false

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
    guard let content = try? String(contentsOfFile: configFile, encoding: .utf8) else { return false }
    for line in content.components(separatedBy: "\n") {
        if line.hasPrefix("subtitle=") {
            return line.replacingOccurrences(of: "subtitle=", with: "") == "on"
        }
    }
    return false
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

func writeActiveSegment(segment: Int = 1, total: Int = 1, preview: String, status: String) {
    let truncPreview = String(preview.prefix(60))
    let content = "segment=\(segment)\ntotal=\(total)\npreview=\(truncPreview)\nstatus=\(status)\n"
    try? content.write(toFile: activeSegmentFile, atomically: true, encoding: .utf8)
}

func clearActiveSegment() {
    try? FileManager.default.removeItem(atPath: activeSegmentFile)
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
    playChime()

    debugPrint("Killed say + afplay, created skip flag")
}

// MARK: - Stop All (shift+shift)

func triggerStopAll() {
    debugPrint("STOP ALL — killing everything")
    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    try? FileManager.default.removeItem(atPath: pauseFlag)
    state.isPaused = false

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

    clearTTYSubtitle()

    // Chime AFTER cleanup so pkill doesn't kill it
    usleep(100_000)
    playChime()
    debugPrint("STOP ALL — everything killed, lock cleared")
}

// MARK: - Repeat (cmd+shift)

func triggerRepeat() {
    debugPrint("REPEAT — replaying last TTS response")
    playChime()

    // Stop any active auto-speak.sh loop via skip flag, then kill audio
    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    killTTSProcesses()
    usleep(300_000) // let auto-speak.sh break its loop and release lock

    // Acquire mutex so no new auto-speak.sh starts while we replay
    acquireTTSLock()
    try? FileManager.default.removeItem(atPath: skipFlag)

    // Read saved state
    guard let text = try? String(contentsOfFile: lastTextFile, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        debugPrint("REPEAT — no saved text, ignoring")
        releaseTTSLock()
        return
    }

    let speed = (try? String(contentsOfFile: lastSpeedFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "300"
    let volume = (try? String(contentsOfFile: lastVolumeFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "1.0"

    // Mark TTS as playing
    FileManager.default.createFile(atPath: ttsPlayingFlag, contents: nil)
    let previewText = String(text.prefix(60))
    writeActiveSegment(preview: previewText, status: "repeat")

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

            showTTYSubtitle(sentence)

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
        clearTTYSubtitle()
        try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
        try? FileManager.default.removeItem(atPath: pauseFlag)
        try? FileManager.default.removeItem(atPath: skipFlag)
        clearActiveSegment()
        releaseTTSLock()
    }
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
    let speed = (try? String(contentsOfFile: configFile, encoding: .utf8)
        .components(separatedBy: "\n")
        .first(where: { $0.hasPrefix("speed=") })?
        .replacingOccurrences(of: "speed=", with: "")) ?? "300"
    let volLine = (try? String(contentsOfFile: configFile, encoding: .utf8)
        .components(separatedBy: "\n")
        .first(where: { $0.hasPrefix("volume=") })?
        .replacingOccurrences(of: "volume=", with: "")) ?? "normal"
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
        try? FileManager.default.removeItem(atPath: pauseFlag)
        try? FileManager.default.removeItem(atPath: skipFlag)
        clearActiveSegment()
        releaseTTSLock()
    }
}

// MARK: - Message Navigation (opt+shift+arrow)

// Extract all assistant text blocks from the transcript using python3.
// Each individual text block is a separate navigable message.
func extractMessagesFromTranscript() -> [String] {
    guard let tPath = try? String(contentsOfFile: transcriptPathFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          FileManager.default.fileExists(atPath: tPath) else {
        debugPrint("MESSAGE NAV — no transcript path")
        return []
    }

    let script = """
    import json, sys
    messages = []
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: entry = json.loads(line)
            except: continue
            if entry.get('type','') == 'assistant':
                content = entry.get('message',{}).get('content',[])
                if isinstance(content, list):
                    for b in content:
                        if b.get('type') == 'text' and b.get('text','').strip():
                            messages.append(b['text'])
    # Output messages separated by null byte
    for msg in messages:
        sys.stdout.write(msg + '\\0')
    """

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = ["-c", script, tPath]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        debugPrint("MESSAGE NAV — python3 failed: \(error)")
        return []
    }

    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return [] }

    return output.components(separatedBy: "\0").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

func triggerMessageNav(direction: String) {
    debugPrint("MESSAGE NAV — \(direction)")

    // Stop any active audio
    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    killTTSProcesses()
    usleep(300_000)

    acquireTTSLock()
    try? FileManager.default.removeItem(atPath: skipFlag)

    // Extract all assistant messages from transcript
    let messages = extractMessagesFromTranscript()
    let total = messages.count

    guard total > 0 else {
        debugPrint("MESSAGE NAV — no messages in transcript")
        playChime()
        releaseTTSLock()
        return
    }

    // Read current nav index (defaults to last message)
    let currentStr = (try? String(contentsOfFile: navIndexFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "\(total - 1)"
    var current = Int(currentStr) ?? (total - 1)
    // Clamp to valid range
    current = min(current, total - 1)

    // Navigate
    if direction == "next" {
        if current >= total - 1 {
            debugPrint("MESSAGE NAV — already at last message (\(current + 1)/\(total))")
            playChime()
            releaseTTSLock()
            return
        }
        current += 1
    } else {
        if current <= 0 {
            debugPrint("MESSAGE NAV — already at first message (1/\(total))")
            playChime()
            releaseTTSLock()
            return
        }
        current -= 1
    }

    // Read speed from voice config
    let speed = (try? String(contentsOfFile: configFile, encoding: .utf8)
        .components(separatedBy: "\n")
        .first(where: { $0.hasPrefix("speed=") })?
        .replacingOccurrences(of: "speed=", with: "")) ?? "300"
    let volLine = (try? String(contentsOfFile: configFile, encoding: .utf8)
        .components(separatedBy: "\n")
        .first(where: { $0.hasPrefix("volume=") })?
        .replacingOccurrences(of: "volume=", with: "")) ?? "normal"
    let volume = volLine == "quiet" ? "0.3" : "1.0"

    // Play from selected message through the end (auto-continue)
    FileManager.default.createFile(atPath: ttsPlayingFlag, contents: nil)
    playChime()

    DispatchQueue.global(qos: .userInitiated).async {
        var msgIdx = current

        while msgIdx < total {
            let text = messages[msgIdx]
            debugPrint("MESSAGE NAV — playing message \(msgIdx + 1)/\(total) (\(text.count) chars)")

            // Save nav index and last-text for repeat
            try? "\(msgIdx)".write(toFile: navIndexFile, atomically: true, encoding: .utf8)
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

                showTTYSubtitle(sentence)

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

                let playProc = Process()
                playProc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                playProc.arguments = ["--volume", volume, tmpFile]
                try? playProc.run()
                playProc.waitUntilExit()

                try? FileManager.default.removeItem(atPath: tmpFile)
                idx += 1
            }

            // If skipped (cmd+cmd or shift+shift), stop auto-continue
            if skipped { break }

            msgIdx += 1
        }

        clearTTYSubtitle()
        try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
        try? FileManager.default.removeItem(atPath: pauseFlag)
        try? FileManager.default.removeItem(atPath: skipFlag)
        releaseTTSLock()
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

if !trusted {
    // Prompt the user to grant Accessibility permission
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    let _ = AXIsProcessTrustedWithOptions(options)
    fputs("⚠ Accessibility permission not granted. A system dialog should appear.\n", stderr)
    fputs("  Add this binary: \(CommandLine.arguments[0])\n", stderr)
    fputs("  System Settings > Privacy & Security > Accessibility\n", stderr)
    debugPrint("Accessibility not granted — prompted user")
    // Continue anyway — the tap may still create but not receive events
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
    fputs("  Grant BOTH permissions to: \(CommandLine.arguments[0])\n", stderr)
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
            fputs("  Binary: \(CommandLine.arguments[0])\n", stderr)
            debugPrint("SELF-TEST FAILED: tap disabled by OS")
            // Re-enable and keep trying — permission might be granted while running
            CGEvent.tapEnable(tap: t, enable: true)
        }
    }
}

// MARK: - Config File Poll (daemon keepalive)

var configMissCount = 0
let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
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
        configMissCount += 1
        debugPrint("Config file missing (count: \(configMissCount)/3)")
        if configMissCount >= 3 {
            debugPrint("Config file gone for 6s — self-terminating")
            cleanupAndExit()
        }
    }
}

RunLoop.current.add(timer, forMode: .common)
CFRunLoopRun()
