import Foundation
import CoreGraphics
import ApplicationServices

// Monitors modifier keys and key combos for voice mode controls:
// - Double-Command tap (cmd+cmd): SKIP — kills audio + mic
// - Double-Control tap (ctrl+ctrl): PAUSE/RESUME — SIGSTOP/SIGCONT
// - Command+Shift (single tap): REPEAT — replay last TTS response
// - Function+Function tap (fn+fn): PLAY LOG — continue playback-log timeline
// - Control+Left/Right (keyDown): FORWARD/REWIND — skip ±1 sentence while speaking;
//   navigate playback-log items while idle
// - Control+Shift+Left/Right (keyDown): MESSAGE NAV — play prev/next history message;
//   skip ±20 lines during an active file read
// - Control+Up/Down (keyDown): SPEED — adjust speech speed ±25 WPM
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
let functionKeyCode: Int64 = 63
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
let lastSessionNameFile = "/tmp/claude-tts-last-session-name"
let playbackCursorFile = "/tmp/claude-tts-playback-cursor"
let currentPlaybackItemFile = "/tmp/claude-tts-current-item-id"
let focusedSessionFile = "/tmp/claude-tts-focused-session-id"
let restartQueueFlag = "/tmp/claude-tts-restart-queue"
let playbackLogDir = "/tmp/claude-tts-playback-log"
let playbackLogItemsDir = "\(playbackLogDir)/items"
let playbackLogManifestFile = "\(playbackLogDir)/manifest.jsonl"
let playbackLogCommandFile = "/tmp/claude-tts-log-command"
let playbackLogRetentionSeconds: TimeInterval = 90 * 60
let playbackLogMaxItems = 200
let backfillInboxDir = "/tmp/claude-tts-backfill-inbox"
let backfillAcknowledgementDir = "/tmp/claude-tts-backfill-acks"
let backfillNavigationAnchorFile = "/tmp/claude-tts-backfill-navigation-anchor"
let deferredQueueDir = "/tmp/claude-tts-deferred-queue"
let deferredQueueMaxItems = 200

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
let stopGenerationFile = "/tmp/claude-tts-stop-generation"
let stopAllRequestFile = "/tmp/claude-tts-stop-all-request"
let autoplayResumeRequestFile = "/tmp/claude-tts-autoplay-resume"
let stopTransactionLockDir = "/tmp/claude-tts-stop-transaction.lock"
let stopTransactionWarningFile = "/tmp/claude-tts-stop-transaction-timeout.warning"
let ttsLockOwnerFile = "/tmp/claude-tts-speaking.lock/owner"

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
    // Control double-tap (pause)
    var lastControlUp: Date?
    var controlIsDown = false
    var lastControlComboUse: Date?
    var isPaused = false
    // Shift double-tap (stop all)
    var lastShiftUp: Date?
    var shiftIsDown = false
    // Function double-tap (play next log item)
    var lastFunctionUp: Date?
    var functionIsDown = false
    // Command+Shift (repeat)
    var cmdShiftTriggered = false
    // Track if a regular key was pressed while cmd+shift held (prevents false triggers)
    var regularKeyDuringCmdShift = false
    // Control+Shift double-tap (drill-down)
    var controlShiftTriggered = false
    var lastControlShiftUp: Date?
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
let stopGenerationStore = StopGenerationStore(
    stateURL: URL(fileURLWithPath: stopGenerationFile)
)

struct SessionPlaybackKey: Equatable {
    let sourceLabel: String
    let sessionID: String
}

var lastAudiblyPlayedSessionKey: SessionPlaybackKey?

final class OwnedProcessRegistry {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func register(_ process: Process) {
        lock.lock()
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let active = Array(processes.values)
        lock.unlock()
        for process in active where process.isRunning {
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(0.25)
        while active.contains(where: { $0.isRunning }) && Date() < deadline {
            usleep(10_000)
        }
        for process in active where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

let ownedProcesses = OwnedProcessRegistry()
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

func playChime(expectedGeneration: StopGenerationSnapshot) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    proc.arguments = ["--volume", chimeVolume, chimeSound]
    _ = runProcessWithTimeout(
        proc,
        timeout: 3,
        expectedGeneration: expectedGeneration
    )
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

func playDoubleTink(expectedGeneration: StopGenerationSnapshot) {
    playChime(expectedGeneration: expectedGeneration)
    guard stopGenerationStore.isCurrent(expectedGeneration) else { return }
    usleep(80_000)
    playChime(expectedGeneration: expectedGeneration)
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

func ensureDirectory(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func acquireStopTransactionLock(maxTicks: Int = 300) -> Bool {
    let fm = FileManager.default
    var waited = 0
    while waited < maxTicks {
        do {
            try fm.createDirectory(
                atPath: stopTransactionLockDir,
                withIntermediateDirectories: false,
                attributes: nil
            )
            return true
        } catch {
            if let attributes = try? fm.attributesOfItem(atPath: stopTransactionLockDir),
               let modified = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > 30 {
                try? fm.removeItem(atPath: stopTransactionLockDir)
                continue
            }
            usleep(10_000)
            waited += 1
        }
    }
    return false
}

func releaseStopTransactionLock() {
    try? FileManager.default.removeItem(atPath: stopTransactionLockDir)
}

func acquireStopTransactionLockForStopAll() -> Bool {
    if acquireStopTransactionLock() {
        try? FileManager.default.removeItem(atPath: stopTransactionWarningFile)
        return true
    }

    debugPrint("STOP ALL — WARNING: stop transaction lock unavailable after 3s; retrying up to 7s")
    for retry in 1...7 {
        if acquireStopTransactionLock(maxTicks: 100) {
            debugPrint("STOP ALL — acquired stop transaction lock on bounded retry \(retry)")
            try? FileManager.default.removeItem(atPath: stopTransactionWarningFile)
            return true
        }
    }

    let warning = "timestamp=\(Date().timeIntervalSince1970)\nreason=stop_transaction_lock_timeout\n"
    do {
        try warning.write(toFile: stopTransactionWarningFile, atomically: true, encoding: .utf8)
    } catch {
        debugPrint("STOP ALL — WARNING: could not write lock-timeout marker: \(error)")
    }
    debugPrint("STOP ALL — WARNING: proceeding after 10s hard cap without stop transaction lock; marker=\(stopTransactionWarningFile)")
    return false
}

func drainLocalStopAllQueues() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [pluginToolPath("stopall-drain.sh"), queueDir, deferredQueueDir]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            debugPrint("STOP ALL — WARNING: queue drain exited \(process.terminationStatus)")
        }
    } catch {
        debugPrint("STOP ALL — WARNING: queue drain failed to launch: \(error)")
    }
}

func uniqueDeferredEntryName(for entry: String) -> String {
    let safeEntry = entry.hasPrefix("entry-") ? String(entry.dropFirst(6)) : entry
    return "entry-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)-\(safeEntry)"
}

func trimDeferredQueueIfNeeded() {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: deferredQueueDir).sorted() else { return }
    let deferredEntries = entries.filter { $0.hasPrefix("entry-") }
    guard deferredEntries.count > deferredQueueMaxItems else { return }

    for entry in deferredEntries.prefix(deferredEntries.count - deferredQueueMaxItems) {
        try? fm.removeItem(atPath: "\(deferredQueueDir)/\(entry)")
    }
}

func deferQueueEntry(entryPath: String, entryName: String, sourceLabel: String?, target: String) {
    let fm = FileManager.default
    ensureDirectory(deferredQueueDir)
    let deferredName = uniqueDeferredEntryName(for: entryName)
    let deferredPath = "\(deferredQueueDir)/\(deferredName)"
    if fm.fileExists(atPath: deferredPath) {
        try? fm.removeItem(atPath: deferredPath)
    }
    try? fm.moveItem(atPath: entryPath, toPath: deferredPath)
    trimDeferredQueueIfNeeded()
    debugPrint("QUEUE — deferred \(entryName) target=\(target) source=\(sourceLabel ?? "unknown") count=\(deferredQueueCount())")
}

func restoreDeferredEntriesIfNeeded(target: String) {
    guard FileManager.default.fileExists(atPath: deferredQueueDir) else { return }
    ensureDirectory(queueDir)

    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: deferredQueueDir).sorted() else { return }

    for entry in entries where entry.hasPrefix("entry-") {
        let deferredPath = "\(deferredQueueDir)/\(entry)"
        let sourceLabel = normalizeSourceLabel(try? String(contentsOfFile: "\(deferredPath)/source", encoding: .utf8))
        guard target == "both" || sourceMatchesTarget(sourceLabel, target: target) else { continue }

        let restoredName = "entry-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        let restoredPath = "\(queueDir)/\(restoredName)"
        try? fm.moveItem(atPath: deferredPath, toPath: restoredPath)
        debugPrint("QUEUE — restored deferred entry for target=\(target) source=\(sourceLabel ?? "unknown")")
    }
}

func shouldProcessDeferredQueue() -> Bool {
    let target = currentTargetScope()
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: deferredQueueDir) else {
        return false
    }

    return entries.contains { entry in
        guard entry.hasPrefix("entry-") else { return false }
        if target == "both" { return true }
        let deferredPath = "\(deferredQueueDir)/\(entry)"
        let sourceLabel = normalizeSourceLabel(try? String(contentsOfFile: "\(deferredPath)/source", encoding: .utf8))
        return sourceMatchesTarget(sourceLabel, target: target)
    }
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

func normalizedTargetScope(_ raw: String?) -> String {
    switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude":
        return "claude"
    case "codex":
        return "codex"
    default:
        return "both"
    }
}

func currentTargetScope() -> String {
    normalizedTargetScope(readConfigValue("target"))
}

func targetDropNonmatchingEnabled() -> Bool {
    readConfigValue("target_drop_nonmatching").lowercased() == "true"
}

func sourceMatchesTarget(_ sourceLabel: String?, target: String) -> Bool {
    guard target != "both" else { return true }
    guard let source = sourceLabel?.lowercased() else { return false }
    if target == "claude" {
        return source.contains("claude")
    }
    if target == "codex" {
        return source.contains("codex")
    }
    return true
}

func sourceMatchesCurrentTarget(_ sourceLabel: String?) -> Bool {
    sourceMatchesTarget(sourceLabel, target: currentTargetScope())
}

func deferredQueueCount() -> Int {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: deferredQueueDir) else {
        return 0
    }
    return entries.filter { $0.hasPrefix("entry-") }.count
}

func queueStatusLabel(base: String) -> String {
    let deferred = deferredQueueCount()
    guard deferred > 0 else { return base }
    return "\(base) deferred=\(deferred)"
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
    sessionID: String?,
    sessionName: String?,
    itemID: String?
)

struct QueueItemMetadata: Codable {
    var schemaVersion: Int?
    var origin: String?
    var autoplay: Bool?
    var batchID: String?
    var batchIndex: Int?
    var turnID: String?
    var answeredAt: TimeInterval?
    var importedAt: TimeInterval?
    var contentHash: String?
    var normalizationVersion: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case origin
        case autoplay
        case batchID = "batch_id"
        case batchIndex = "batch_index"
        case turnID = "turn_id"
        case answeredAt = "answered_at"
        case importedAt = "imported_at"
        case contentHash = "content_hash"
        case normalizationVersion = "normalization_version"
    }
}

struct PlaybackSentence: Codable {
    var index: Int
    var text: String
    var audioFile: String?
}

struct PlaybackLogItem: Codable {
    var id: String
    var timestamp: TimeInterval
    var sourceLabel: String?
    var sessionID: String?
    var sessionName: String?
    var requestedEngine: String
    var engine: String
    var fallbackReason: String?
    var speed: String
    var volume: String
    var blockID: String?
    var itemDir: String
    var rawTextPath: String
    var normalizedTextPath: String
    var sentenceMapPath: String
    var playbackState: String?
    var playedAt: TimeInterval?
    var skippedAt: TimeInterval?
    var schemaVersion: Int?
    var origin: String?
    var autoplay: Bool?
    var batchID: String?
    var batchIndex: Int?
    var turnID: String?
    var answeredAt: TimeInterval?
    var importedAt: TimeInterval?
    var contentHash: String?
    var normalizationVersion: Int?

    var preview: String {
        let base = String((try? String(contentsOfFile: normalizedTextPath, encoding: .utf8))?.prefix(60) ?? "")
        if let sourceLabel {
            return "[\(sourceLabel)] \(base)"
        }
        return base
    }
}

func splitSentences(_ text: String) -> [String] {
    let nsText = text as NSString
    var sentences: [String] = []

    nsText.enumerateSubstrings(
        in: NSRange(location: 0, length: nsText.length),
        options: [.bySentences, .localized]
    ) { _, range, _, _ in
        guard range.location != NSNotFound else { return }
        let sentence = nsText.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !sentence.isEmpty {
            sentences.append(sentence)
        }
    }

    if !sentences.isEmpty {
        return sentences
    }

    return text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
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

func currentRequestedEngine() -> String {
    let value = readConfigValue("engine")
    return value == "openai" ? "openai" : "say"
}

func currentOpenAIVoice() -> String {
    let value = readConfigValue("openai_voice")
    return value.isEmpty ? "nova" : value
}

func playbackLogItemDirectory(id: String) -> String {
    "\(playbackLogItemsDir)/\(id)"
}

func ensurePlaybackLogDirectories() {
    let fm = FileManager.default
    try? fm.createDirectory(
        atPath: playbackLogItemsDir,
        withIntermediateDirectories: true,
        attributes: nil
    )
}

func writeString(_ value: String, to path: String) {
    try? value.write(toFile: path, atomically: true, encoding: .utf8)
}

func loadPlaybackLogItems() -> [PlaybackLogItem] {
    guard let content = try? String(contentsOfFile: playbackLogManifestFile, encoding: .utf8) else {
        return []
    }

    let decoder = JSONDecoder()
    return content
        .components(separatedBy: "\n")
        .compactMap { line -> PlaybackLogItem? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
                return nil
            }
            return try? decoder.decode(PlaybackLogItem.self, from: data)
        }
        .sorted {
            let lhs = backfillOrderingTime(answeredAt: $0.answeredAt, legacyTimestamp: $0.timestamp)
            let rhs = backfillOrderingTime(answeredAt: $1.answeredAt, legacyTimestamp: $1.timestamp)
            if lhs == rhs { return $0.timestamp < $1.timestamp }
            return lhs < rhs
        }
}

func savePlaybackLogItems(_ items: [PlaybackLogItem]) {
    ensurePlaybackLogDirectories()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let lines = items.compactMap { item -> String? in
        guard let data = try? encoder.encode(item) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    writeString(content, to: playbackLogManifestFile)
}

@discardableResult
func prunePlaybackLog() -> [PlaybackLogItem] {
    ensurePlaybackLogDirectories()
    let fm = FileManager.default
    let cutoff = Date().timeIntervalSince1970 - playbackLogRetentionSeconds
    var items = loadPlaybackLogItems()
    items = items.filter { item in
        if backfillRetentionTime(importedAt: item.importedAt, legacyTimestamp: item.timestamp) >= cutoff {
            return true
        }
        try? fm.removeItem(atPath: item.itemDir)
        return false
    }

    if items.count > playbackLogMaxItems {
        let toRemove = items.count - playbackLogMaxItems
        for item in items.prefix(toRemove) {
            try? fm.removeItem(atPath: item.itemDir)
        }
        items = Array(items.suffix(playbackLogMaxItems))
    }

    savePlaybackLogItems(items)
    return items
}

func loadSentenceMap(for item: PlaybackLogItem) -> [PlaybackSentence] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: item.sentenceMapPath)) else {
        return []
    }
    return (try? JSONDecoder().decode([PlaybackSentence].self, from: data)) ?? []
}

func saveSentenceMap(_ sentences: [PlaybackSentence], for item: PlaybackLogItem) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(sentences) else { return }
    try? data.write(to: URL(fileURLWithPath: item.sentenceMapPath), options: .atomic)
}

func updatePlaybackLogItem(_ updatedItem: PlaybackLogItem) {
    var items = prunePlaybackLog()
    guard let idx = items.firstIndex(where: { $0.id == updatedItem.id }) else { return }
    items[idx] = updatedItem
    savePlaybackLogItems(items)
}

func readCurrentPlaybackItemID() -> String? {
    normalizeSessionID(try? String(contentsOfFile: currentPlaybackItemFile, encoding: .utf8))
}

func writeCurrentPlaybackItemID(_ id: String?) {
    guard let id else {
        try? FileManager.default.removeItem(atPath: currentPlaybackItemFile)
        return
    }
    writeString(id, to: currentPlaybackItemFile)
}

func writeBackfillNavigationAnchor(_ id: String) {
    writeString(id, to: backfillNavigationAnchorFile)
}

func readBackfillNavigationAnchor() -> String? {
    normalizeSessionID(try? String(contentsOfFile: backfillNavigationAnchorFile, encoding: .utf8))
}

func focusedPlaybackLogItems(prune: Bool = true) -> [PlaybackLogItem] {
    let target = currentTargetScope()
    let sourceItems = prune ? prunePlaybackLog() : loadPlaybackLogItems()
    let items = sourceItems.filter { sourceMatchesTarget($0.sourceLabel, target: target) }
    guard let focusedSession = readFocusedSessionID() else {
        return items
    }
    return items.filter { $0.sessionID == focusedSession }
}

func findPlaybackLogItem(id: String) -> PlaybackLogItem? {
    loadPlaybackLogItems().first { $0.id == id }
}

func currentPlaybackLogItem() -> PlaybackLogItem? {
    let filtered = focusedPlaybackLogItems()
    guard !filtered.isEmpty else { return nil }

    if let currentID = readCurrentPlaybackItemID(),
       let item = filtered.first(where: { $0.id == currentID }) {
        return item
    }

    let latest = filtered.last
    writeCurrentPlaybackItemID(latest?.id)
    return latest
}

func resetPlaybackLogCursorToLatest(prune: Bool = true) {
    let latest = focusedPlaybackLogItems(prune: prune).last
    writeCurrentPlaybackItemID(latest?.id)
    writePlaybackCursor(0)
}

func playbackLogFirstItem() -> PlaybackLogItem? {
    let items = focusedPlaybackLogItems()
    guard let first = items.first else { return nil }
    writeCurrentPlaybackItemID(first.id)
    writePlaybackCursor(0)
    return first
}

func playbackLogTimelineItem() -> PlaybackLogItem? {
    let items = focusedPlaybackLogItems()
    guard !items.isEmpty else { return nil }

    let target: PlaybackLogItem
    if let currentID = readCurrentPlaybackItemID(),
       let idx = items.firstIndex(where: { $0.id == currentID }) {
        let nextIndex = min(idx + 1, items.count - 1)
        target = items[nextIndex]
    } else {
        target = items[0]
    }

    writeCurrentPlaybackItemID(target.id)
    writePlaybackCursor(0)
    return target
}

func rewritePlaybackTexts(rawText: String, normalizedText: String, item: PlaybackLogItem) {
    writeString(rawText, to: item.rawTextPath)
    writeString(normalizedText, to: item.normalizedTextPath)
}

func readQueueItemMetadata(at path: String) -> QueueItemMetadata? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(QueueItemMetadata.self, from: data)
}

func upsertPlaybackLogItem(
    blockID: String?,
    rawText: String,
    normalizedText: String,
    sourceLabel: String?,
    sessionID: String?,
    sessionName: String?,
    speed: String,
    volume: String,
    metadata: QueueItemMetadata? = nil,
    timestamp: TimeInterval? = nil,
    playbackState: String? = nil,
    skippedAt: TimeInterval? = nil,
    pruneBeforeUpsert: Bool = true,
    mergeBlockUpdates: Bool = true
) -> (item: PlaybackLogItem, sentenceOffset: Int, newSentenceText: String?) {
    ensurePlaybackLogDirectories()
    var items = pruneBeforeUpsert ? prunePlaybackLog() : loadPlaybackLogItems()
    let fm = FileManager.default

    let normalizedSentences = splitSentences(normalizedText)
    let requestedEngine = currentRequestedEngine()

    if mergeBlockUpdates, let blockID,
       let idx = items.lastIndex(where: {
           $0.blockID == blockID && $0.sessionID == sessionID && $0.sourceLabel == sourceLabel
       }) {
        var item = items[idx]
        let oldSentences = loadSentenceMap(for: item)
        let existingTexts = oldSentences.map(\.text)
        var prefixCount = 0
        while prefixCount < existingTexts.count &&
            prefixCount < normalizedSentences.count &&
            existingTexts[prefixCount] == normalizedSentences[prefixCount] {
            prefixCount += 1
        }

        var updatedSentences = Array(oldSentences.prefix(prefixCount))
        for (offset, sentenceText) in normalizedSentences.dropFirst(prefixCount).enumerated() {
            updatedSentences.append(
                PlaybackSentence(index: prefixCount + offset, text: sentenceText, audioFile: nil)
            )
        }
        for idx in updatedSentences.indices {
            updatedSentences[idx].index = idx
        }

        item.timestamp = timestamp ?? Date().timeIntervalSince1970
        item.speed = speed
        item.volume = volume
        item.sessionName = sessionName ?? item.sessionName
        item.requestedEngine = requestedEngine
        if let playbackState {
            item.playbackState = playbackState
        }
        if let skippedAt {
            item.skippedAt = skippedAt
        }
        if let metadata {
            item.schemaVersion = metadata.schemaVersion
            item.origin = metadata.origin
            item.autoplay = metadata.autoplay
            item.batchID = metadata.batchID
            item.batchIndex = metadata.batchIndex
            item.turnID = metadata.turnID
            item.answeredAt = metadata.answeredAt
            item.importedAt = metadata.importedAt
            item.contentHash = metadata.contentHash
            item.normalizationVersion = metadata.normalizationVersion
        }
        rewritePlaybackTexts(rawText: rawText, normalizedText: normalizedText, item: item)
        saveSentenceMap(updatedSentences, for: item)
        items[idx] = item
        savePlaybackLogItems(items)

        let newSentenceText = prefixCount < normalizedSentences.count
            ? normalizedSentences.dropFirst(prefixCount).joined(separator: " ")
            : nil
        return (item, prefixCount, newSentenceText)
    }

    let itemID = "item-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
    let itemDir = playbackLogItemDirectory(id: itemID)
    try? fm.createDirectory(atPath: itemDir, withIntermediateDirectories: true, attributes: nil)
    try? fm.createDirectory(atPath: "\(itemDir)/audio", withIntermediateDirectories: true, attributes: nil)

    let item = PlaybackLogItem(
        id: itemID,
        timestamp: timestamp ?? Date().timeIntervalSince1970,
        sourceLabel: sourceLabel,
        sessionID: sessionID,
        sessionName: sessionName,
        requestedEngine: requestedEngine,
        engine: requestedEngine,
        fallbackReason: nil,
        speed: speed,
        volume: volume,
        blockID: blockID,
        itemDir: itemDir,
        rawTextPath: "\(itemDir)/raw.txt",
        normalizedTextPath: "\(itemDir)/normalized.txt",
        sentenceMapPath: "\(itemDir)/sentence-map.json",
        playbackState: playbackState,
        playedAt: nil,
        skippedAt: skippedAt,
        schemaVersion: metadata?.schemaVersion,
        origin: metadata?.origin,
        autoplay: metadata?.autoplay,
        batchID: metadata?.batchID,
        batchIndex: metadata?.batchIndex,
        turnID: metadata?.turnID,
        answeredAt: metadata?.answeredAt,
        importedAt: metadata?.importedAt,
        contentHash: metadata?.contentHash,
        normalizationVersion: metadata?.normalizationVersion
    )
    rewritePlaybackTexts(rawText: rawText, normalizedText: normalizedText, item: item)
    let sentenceMap = normalizedSentences.enumerated().map { offset, sentenceText in
        PlaybackSentence(index: offset, text: sentenceText, audioFile: nil)
    }
    saveSentenceMap(sentenceMap, for: item)
    items.append(item)
    savePlaybackLogItems(items)
    return (item, 0, normalizedSentences.isEmpty ? nil : normalizedSentences.joined(separator: " "))
}

func importPendingBackfillBatches() {
    importBackfillBatches(
        inboxURL: URL(fileURLWithPath: backfillInboxDir),
        acknowledgementURL: URL(fileURLWithPath: backfillAcknowledgementDir),
        isGenerationCurrent: { generation in
            stopGenerationStore.snapshot().generation == generation
        }
    ) { batch, generation in
        let snapshot = stopGenerationStore.snapshot()
        let expected = StopGenerationSnapshot(
            generation: generation,
            timestamp: snapshot.timestamp,
            autoplayHold: snapshot.autoplayHold
        )
        return stopGenerationStore.valueIfCurrent(expected) {
            var existing = loadPlaybackLogItems()
            var knownHashes = BackfillDedupIndex()
            for index in existing.indices {
                guard existing[index].sourceLabel == batch.manifest.source,
                      existing[index].sessionID == batch.manifest.sessionID else { continue }
                if let text = try? String(contentsOfFile: existing[index].rawTextPath, encoding: .utf8) {
                    let hash = backfillContentHash(text)
                    existing[index].contentHash = hash
                    existing[index].normalizationVersion = 1
                    knownHashes.insert(source: batch.manifest.source, sessionID: batch.manifest.sessionID, contentHash: hash)
                } else if let hash = existing[index].contentHash, !hash.isEmpty {
                    knownHashes.insert(source: batch.manifest.source, sessionID: batch.manifest.sessionID, contentHash: hash)
                }
            }
            insertBackfillQueueHashes(
                into: &knownHashes,
                queueURL: URL(fileURLWithPath: queueDir),
                source: batch.manifest.source,
                sessionID: batch.manifest.sessionID
            )
            savePlaybackLogItems(existing)

            var imported = 0
            var skipped = batch.manifest.skipped ?? 0
            var dupes = 0
            var newestItemID: String?
            for payload in batch.items {
                let hash = payload.metadata.contentHash ?? backfillContentHash(payload.fullText)
                if knownHashes.contains(source: payload.source, sessionID: payload.sessionID, contentHash: hash) {
                    dupes += 1
                    continue
                }
                guard payload.source == batch.manifest.source,
                      payload.sessionID == batch.manifest.sessionID else {
                    skipped += 1
                    continue
                }
                let metadata = QueueItemMetadata(
                    schemaVersion: payload.metadata.schemaVersion,
                    origin: "backfill",
                    autoplay: false,
                    batchID: payload.metadata.batchID,
                    batchIndex: payload.metadata.batchIndex,
                    turnID: payload.metadata.turnID,
                    answeredAt: payload.metadata.answeredAt,
                    importedAt: Date().timeIntervalSince1970,
                    contentHash: hash,
                    normalizationVersion: payload.metadata.normalizationVersion ?? 1
                )
                let result = upsertPlaybackLogItem(
                    blockID: nil,
                    rawText: payload.fullText,
                    normalizedText: payload.speechText,
                    sourceLabel: payload.source,
                    sessionID: payload.sessionID,
                    sessionName: payload.sessionName,
                    speed: currentSpeechSpeed(),
                    volume: "1.0",
                    metadata: metadata,
                    timestamp: payload.metadata.answeredAt ?? Date().timeIntervalSince1970,
                    playbackState: "unplayed",
                    pruneBeforeUpsert: false,
                    mergeBlockUpdates: false
                )
                knownHashes.insert(source: payload.source, sessionID: payload.sessionID, contentHash: hash)
                newestItemID = result.item.id
                imported += 1
            }
            _ = prunePlaybackLog()
            if let newestItemID {
                writeBackfillNavigationAnchor(newestItemID)
                writeCurrentPlaybackItemID(newestItemID)
            }
            debugPrint("BACKFILL — batch \(batch.id) imported=\(imported) skipped=\(skipped) dupes=\(dupes)")
            return BackfillCommitResult(imported: imported, skipped: skipped, dupes: dupes)
        }
    }
}

func archiveQueueEntryToPlaybackLog(_ entryURL: URL) -> String? {
    let entryPath = entryURL.path
    guard let text = try? String(contentsOf: entryURL.appendingPathComponent("text"), encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        debugPrint("STOP ALL — incomplete committed entry retained: \(entryPath)")
        return nil
    }

    if let existingItemID = normalizeSessionID(
        try? String(contentsOf: entryURL.appendingPathComponent("playback-item-id"), encoding: .utf8)
    ), markPlaybackLogItemSkipped(id: existingItemID) {
        debugPrint("STOP ALL — retained cached playback item \(existingItemID) for \(entryPath)")
        return existingItemID
    }

    let speed = (try? String(contentsOf: entryURL.appendingPathComponent("speed"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "300"
    let volume = (try? String(contentsOf: entryURL.appendingPathComponent("volume"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "1.0"
    let sourceLabel = normalizeSourceLabel(
        try? String(contentsOf: entryURL.appendingPathComponent("source"), encoding: .utf8)
    )
    let sessionID = normalizeSessionID(
        try? String(contentsOf: entryURL.appendingPathComponent("session"), encoding: .utf8)
    )
    let sessionName = normalizeSessionID(
        try? String(contentsOf: entryURL.appendingPathComponent("session_name"), encoding: .utf8)
    )
    let blockID = normalizeSessionID(
        try? String(contentsOf: entryURL.appendingPathComponent("block"), encoding: .utf8)
    )
    let rawText = (try? String(contentsOf: entryURL.appendingPathComponent("raw"), encoding: .utf8)) ?? text
    let normalizedText = (try? String(
        contentsOf: entryURL.appendingPathComponent("normalized"),
        encoding: .utf8
    )) ?? text
    let metadata = readQueueItemMetadata(at: entryURL.appendingPathComponent("meta.json").path)
    let modified = (try? entryURL.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970

    let result = upsertPlaybackLogItem(
        blockID: blockID,
        rawText: rawText,
        normalizedText: normalizedText,
        sourceLabel: sourceLabel,
        sessionID: sessionID,
        sessionName: sessionName,
        speed: speed,
        volume: volume,
        metadata: metadata,
        timestamp: modified,
        playbackState: "skipped",
        skippedAt: Date().timeIntervalSince1970,
        pruneBeforeUpsert: false,
        mergeBlockUpdates: false
    )
    debugPrint("STOP ALL — archived \(entryPath) as \(result.item.id)")
    return result.item.id
}

@discardableResult
func markPlaybackLogItemSkipped(id: String) -> Bool {
    var items = loadPlaybackLogItems()
    guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
    items[index].playbackState = "skipped"
    items[index].skippedAt = Date().timeIntervalSince1970
    savePlaybackLogItems(items)
    return true
}

func markPlaybackLogItemPlayback(id: String, completed: Bool) {
    var items = loadPlaybackLogItems()
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].playbackState = completed ? "played" : "partial"
    if completed {
        items[index].playedAt = Date().timeIntervalSince1970
    }
    savePlaybackLogItems(items)
}

func markCurrentPlaybackItemSkipped() {
    guard let currentID = readCurrentPlaybackItemID() else { return }
    _ = markPlaybackLogItemSkipped(id: currentID)
}

@discardableResult
func archivePendingQueueEntries(
    discardStaging: Bool,
    onlyHeldEntries: Bool
) -> [String] {
    let directories = [URL(fileURLWithPath: queueDir), URL(fileURLWithPath: deferredQueueDir)]
    let archivedIDs = archiveStopAllQueueEntries(
        in: directories,
        discardStaging: discardStaging
    ) { entryURL in
        if onlyHeldEntries {
            let archiveOnly = FileManager.default.fileExists(
                atPath: entryURL.appendingPathComponent("archive-only").path
            )
            let modified = (try? entryURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            guard stopGenerationStore.queueDisposition(
                modificationTime: modified,
                archiveOnly: archiveOnly
            ) == .archive else {
                return nil
            }
        }
        return archiveQueueEntryToPlaybackLog(entryURL)
    }

    if !archivedIDs.isEmpty && (!onlyHeldEntries || stopGenerationStore.isAutoplayHeld()) {
        writeCurrentPlaybackItemID(archivedIDs.last)
        writePlaybackCursor(0)
    }
    return archivedIDs
}

func cachedSentenceAudioPath(itemID: String, sentenceIndex: Int) -> String? {
    guard let item = findPlaybackLogItem(id: itemID) else { return nil }
    let sentenceMap = loadSentenceMap(for: item)
    guard sentenceIndex >= 0, sentenceIndex < sentenceMap.count,
          let audioFile = sentenceMap[sentenceIndex].audioFile,
          FileManager.default.fileExists(atPath: audioFile) else {
        return nil
    }
    return audioFile
}

func updatePlaybackLogAudioState(
    itemID: String,
    sentenceIndex: Int,
    audioFile: String,
    actualEngine: String,
    fallbackReason: String?
) {
    guard var item = findPlaybackLogItem(id: itemID) else { return }
    var sentenceMap = loadSentenceMap(for: item)
    guard sentenceIndex >= 0, sentenceIndex < sentenceMap.count else { return }
    sentenceMap[sentenceIndex].audioFile = audioFile
    item.engine = actualEngine
    if let fallbackReason {
        item.fallbackReason = fallbackReason
    }
    saveSentenceMap(sentenceMap, for: item)
    updatePlaybackLogItem(item)
}

func readFocusedSessionID() -> String? {
    normalizeSessionID(try? String(contentsOfFile: focusedSessionFile, encoding: .utf8))
}

func queueEntrySessionID(_ entryPath: String) -> String? {
    normalizeSessionID(try? String(contentsOfFile: "\(entryPath)/session", encoding: .utf8))
}

func prioritizeQueueEntries(_ entries: [String], in queueDir: String) -> [String] {
    guard let focusedSession = readFocusedSessionID() else {
        return entries
    }

    var matching: [String] = []
    var remaining: [String] = []

    for entry in entries {
        let entryPath = "\(queueDir)/\(entry)"
        if queueEntrySessionID(entryPath) == focusedSession {
            matching.append(entry)
        } else {
            remaining.append(entry)
        }
    }

    if !matching.isEmpty {
        debugPrint("QUEUE — prioritizing \(matching.count) entries for focused session \(focusedSession)")
    }

    return matching + remaining
}

func shouldRestartQueuePlayback() -> Bool {
    FileManager.default.fileExists(atPath: restartQueueFlag)
}

func markControlComboUse() {
    state.lastControlComboUse = Date()
    state.lastControlUp = nil
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

func runProcessWithTimeout(
    _ process: Process,
    timeout: TimeInterval,
    expectedGeneration: StopGenerationSnapshot? = nil,
    onStarted: (() -> Void)? = nil
) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        semaphore.signal()
    }

    ownedProcesses.register(process)
    defer { ownedProcesses.unregister(process) }

    do {
        if let expectedGeneration {
            let launched = try stopGenerationStore.performIfCurrent(expectedGeneration) {
                try launchProcess(process, onStarted: onStarted)
            }
            guard launched else { return false }
        } else {
            try launchProcess(process, onStarted: onStarted)
        }
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

func waitWhilePaused(expectedGeneration: StopGenerationSnapshot) -> Bool {
    while FileManager.default.fileExists(atPath: pauseFlag) {
        guard stopGenerationStore.isCurrent(expectedGeneration) else { return false }
        state.isPaused = true
        if FileManager.default.fileExists(atPath: skipFlag) {
            return false
        }
        usleep(150_000)
    }
    guard stopGenerationStore.isCurrent(expectedGeneration) else { return false }
    state.isPaused = false
    return true
}

func speakTextBinaryPath() -> String {
    pluginToolPath("speak-text")
}

struct SynthesisResult {
    let success: Bool
    let actualEngine: String
    let fallbackReason: String?
    let outputFile: String?
}

func synthesizeWithSay(
    _ spokenText: String,
    speed: String,
    outputBasePath: String,
    expectedGeneration: StopGenerationSnapshot
) -> SynthesisResult {
    let textFile = "/tmp/claude-tts-say-\(ProcessInfo.processInfo.processIdentifier).txt"
    let outputFile = "\(outputBasePath).aiff"
    try? spokenText.write(toFile: textFile, atomically: true, encoding: .utf8)

    let sayProc = Process()
    sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    sayProc.arguments = ["-r", currentSpeechSpeed(fallback: speed), "-f", textFile, "-o", outputFile]
    let success = runProcessWithTimeout(
        sayProc,
        timeout: 15,
        expectedGeneration: expectedGeneration
    )
    try? FileManager.default.removeItem(atPath: textFile)

    if !success {
        try? FileManager.default.removeItem(atPath: outputFile)
        return SynthesisResult(success: false, actualEngine: "say", fallbackReason: nil, outputFile: nil)
    }

    return SynthesisResult(
        success: FileManager.default.fileExists(atPath: outputFile),
        actualEngine: "say",
        fallbackReason: nil,
        outputFile: outputFile
    )
}

func synthesizeSpeechAudio(
    _ spokenText: String,
    speed: String,
    requestedEngine: String,
    openAIVoice: String,
    outputBasePath: String,
    expectedGeneration: StopGenerationSnapshot
) -> SynthesisResult {
    if requestedEngine == "openai" {
        let outputFile = "\(outputBasePath).mp3"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: speakTextBinaryPath())
        proc.arguments = [
            "-voice", openAIVoice,
            "-output", outputFile,
            "-no-play",
            spokenText,
        ]
        let success = runProcessWithTimeout(
            proc,
            timeout: 30,
            expectedGeneration: expectedGeneration
        )
        if success && FileManager.default.fileExists(atPath: outputFile) {
            return SynthesisResult(
                success: true,
                actualEngine: "openai",
                fallbackReason: nil,
                outputFile: outputFile
            )
        }

        try? FileManager.default.removeItem(atPath: outputFile)
        let fallback = synthesizeWithSay(
            spokenText,
            speed: speed,
            outputBasePath: outputBasePath,
            expectedGeneration: expectedGeneration
        )
        return SynthesisResult(
            success: fallback.success,
            actualEngine: fallback.actualEngine,
            fallbackReason: "openai_unavailable_or_failed",
            outputFile: fallback.outputFile
        )
    }

    return synthesizeWithSay(
        spokenText,
        speed: speed,
        outputBasePath: outputBasePath,
        expectedGeneration: expectedGeneration
    )
}

func playAudioFile(
    _ path: String,
    volume: String,
    expectedGeneration: StopGenerationSnapshot,
    onStarted: (() -> Void)? = nil
) -> Bool {
    let playProc = Process()
    playProc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    playProc.arguments = ["--volume", volume, path]
    return runProcessWithTimeout(
        playProc,
        timeout: 20,
        expectedGeneration: expectedGeneration,
        onStarted: onStarted
    )
}

// Audio mutex — same lock as auto-speak.sh so repeat/nav don't overlap with hook TTS
let ttsLockDir = "/tmp/claude-tts-speaking.lock"
let ttsLockPidFile = "/tmp/claude-tts-speaking.lock/pid"

func acquireTTSLock(expectedGeneration: StopGenerationSnapshot) -> String? {
    let fm = FileManager.default
    let ownerToken = UUID().uuidString
    while true {
        guard stopGenerationStore.isCurrent(expectedGeneration) else { return nil }
        do {
            let claimed = try stopGenerationStore.performIfCurrent(expectedGeneration) {
                try fm.createDirectory(
                    atPath: ttsLockDir,
                    withIntermediateDirectories: false,
                    attributes: nil
                )
                try "\(ProcessInfo.processInfo.processIdentifier)".write(
                    toFile: ttsLockPidFile, atomically: true, encoding: .utf8)
                try ownerToken.write(toFile: ttsLockOwnerFile, atomically: true, encoding: .utf8)
            }
            guard claimed else { return nil }
            debugPrint("TTS lock acquired")
            return ownerToken
        } catch {
            // Lock exists — check if holder is alive
            if let pidStr = try? String(contentsOfFile: ttsLockPidFile, encoding: .utf8),
               let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if kill(pid, 0) == 0 {
                    // Holder alive — wait
                    usleep(300_000)
                } else {
                    // Stale lock — reclaim
                    _ = stopGenerationStore.performIfCurrent(expectedGeneration) {
                        let currentPid = try? String(contentsOfFile: ttsLockPidFile, encoding: .utf8)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if currentPid == String(pid) {
                            try? fm.removeItem(atPath: ttsLockDir)
                        }
                    }
                    debugPrint("Removed stale TTS lock (pid \(pid) dead)")
                }
            } else {
                _ = stopGenerationStore.performIfCurrent(expectedGeneration) {
                    if !fm.fileExists(atPath: ttsLockPidFile) &&
                        !fm.fileExists(atPath: ttsLockOwnerFile) {
                        try? fm.removeItem(atPath: ttsLockDir)
                    }
                }
            }
        }
    }
}

func releaseTTSLock(ownerToken: String) {
    guard let currentOwner = try? String(contentsOfFile: ttsLockOwnerFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          currentOwner == ownerToken else {
        debugPrint("TTS lock release ignored for stale owner")
        return
    }
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
    try? FileManager.default.removeItem(atPath: restartQueueFlag)
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
    let hadActivePlayback = FileManager.default.fileExists(atPath: ttsPlayingFlag) ||
        FileManager.default.fileExists(atPath: ttsLockDir)
    let ownsTransactionLock = acquireStopTransactionLockForStopAll()
    let stoppedGeneration = stopGenerationStore.advance()
    if !stopGenerationStore.isPersistenceHealthy() {
        debugPrint("STOP ALL — generation persistence failed; autoplay remains fail-closed")
    }
    ownedProcesses.terminateAll()
    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    for requestFile in [
        restartQueueFlag,
        pauseFlag,
        forwardFlag,
        rewindFlag,
        bigForwardFlag,
        bigRewindFlag,
        drillDownFlag,
        playbackLogCommandFile,
        autoplayResumeRequestFile,
        voiceInputStopFlag,
        navIndexFile,
    ] {
        try? FileManager.default.removeItem(atPath: requestFile)
    }
    state.isPaused = false

    if hadActivePlayback {
        markCurrentPlaybackItemSkipped()
    }
    let archivedIDs = archivePendingQueueEntries(
        discardStaging: true,
        onlyHeldEntries: false
    )
    drainLocalStopAllQueues()

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
    clearTTYSubtitle()
    try? FileManager.default.removeItem(atPath: skipFlag)
    writeCurrentPlaybackItemID(
        stopAllCursorItemID(
            archivedIDs: archivedIDs,
            manifestLatestID: loadPlaybackLogItems().last?.id
        )
    )
    writePlaybackCursor(0)
    if ownsTransactionLock {
        releaseStopTransactionLock()
    }
    debugPrint("STOP ALL — generation \(stoppedGeneration.generation), archived \(archivedIDs.count) queued item(s), autoplay held")
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
    let sessionID = normalizeSessionID(try? String(contentsOfFile: "\(histDir)/msg-\(padded).session", encoding: .utf8))
    let sessionName = normalizeSessionID(try? String(contentsOfFile: "\(histDir)/msg-\(padded).session_name", encoding: .utf8))

    return (
        text: text,
        speed: speed,
        volume: volume,
        sourceLabel: sourceLabel,
        sessionID: sessionID,
        sessionName: sessionName,
        itemID: nil
    )
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

func historyPlaybackTarget(
    direction: String? = nil,
    useFirst: Bool = false,
    useLatest: Bool = false,
    timeline: Bool = false
) -> (context: PlaybackContext, index: Int, total: Int)? {
    let total = historyMessageTotal()
    guard total > 0 else { return nil }

    let defaultIndex = min(max(getRepeatAnchor() - 1, 0), total - 1)
    let savedIndex = (try? String(contentsOfFile: navIndexFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines))
        .flatMap { Int($0) }
    let current = min(max(savedIndex ?? defaultIndex, 0), total - 1)

    let target: Int
    if useFirst {
        target = 0
    } else if useLatest {
        target = total - 1
    } else if direction == "next" {
        guard current < total - 1 else { return nil }
        target = current + 1
    } else if direction == "prev" {
        guard current > 0 else { return nil }
        target = current - 1
    } else if timeline {
        target = savedIndex == nil ? defaultIndex : min(current + 1, total - 1)
    } else {
        target = current
    }

    guard let context = readHistoryMessage(at: target + 1) else {
        return nil
    }

    try? "\(target)".write(toFile: navIndexFile, atomically: true, encoding: .utf8)
    try? "\(target + 1)".write(toFile: repeatAnchorFile, atomically: true, encoding: .utf8)
    return (context: context, index: target, total: total)
}

@discardableResult
func triggerHistoryPlaybackAction(
    direction: String? = nil,
    useFirst: Bool = false,
    useLatest: Bool = false,
    timeline: Bool = false,
    status: String,
    expectedGeneration: StopGenerationSnapshot? = nil
) -> Bool {
    let playbackGeneration = expectedGeneration ?? stopGenerationStore.snapshot()
    guard stopGenerationStore.isCurrent(playbackGeneration) else { return false }
    guard let target = historyPlaybackTarget(
        direction: direction,
        useFirst: useFirst,
        useLatest: useLatest,
        timeline: timeline
    ) else {
        return false
    }

    interruptPlaybackForReplay()

    DispatchQueue.global(qos: .userInitiated).async {
        guard waitForPlaybackLockRelease(expectedGeneration: playbackGeneration) else { return }
        debugPrint("HISTORY LOG — playing \(target.index + 1)/\(target.total) status=\(status)")
        playContext(
            target.context,
            startIndex: 0,
            status: status,
            expectedGeneration: playbackGeneration
        )
    }

    return true
}

func playbackContext(from item: PlaybackLogItem) -> PlaybackContext? {
    guard let text = try? String(contentsOfFile: item.normalizedTextPath, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

    return (
        text: text,
        speed: item.speed,
        volume: item.volume,
        sourceLabel: item.sourceLabel,
        sessionID: item.sessionID,
        sessionName: item.sessionName,
        itemID: item.id
    )
}

func persistPlaybackContext(_ context: PlaybackContext) {
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

    if let sessionName = context.sessionName {
        try? sessionName.write(toFile: lastSessionNameFile, atomically: true, encoding: .utf8)
    } else {
        try? FileManager.default.removeItem(atPath: lastSessionNameFile)
    }

    writeCurrentPlaybackItemID(context.itemID)
}

func loadReplayContext() -> PlaybackContext? {
    if let currentItem = currentPlaybackLogItem(),
       let context = playbackContext(from: currentItem) {
        return context
    }

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
    let sessionName = normalizeSessionID(try? String(contentsOfFile: lastSessionNameFile, encoding: .utf8))

    return (
        text: text,
        speed: speed,
        volume: volume,
        sourceLabel: sourceLabel,
        sessionID: sessionID,
        sessionName: sessionName,
        itemID: nil
    )
}

func currentCueMode() -> String {
    let raw = readConfigValue("cue").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if raw == "on" {
        writeConfigValue("cue", value: "session")
        return "session"
    }
    switch raw {
    case "source", "both", "off":
        return raw
    case "session", "":
        return "session"
    default:
        return "session"
    }
}

func currentCueFrequency() -> String {
    readConfigValue("cue_frequency").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "always"
        ? "always"
        : "change"
}

func playbackSessionKey(sourceLabel: String?, sessionID: String?) -> SessionPlaybackKey? {
    guard let source = normalizeSourceLabel(sourceLabel),
          let session = normalizeSessionID(sessionID) else { return nil }
    return SessionPlaybackKey(sourceLabel: source, sessionID: session)
}

func noteAudiblePlayback(sourceLabel: String?, sessionID: String?) {
    if let key = playbackSessionKey(sourceLabel: sourceLabel, sessionID: sessionID) {
        lastAudiblyPlayedSessionKey = key
    }
}

func playSessionAnnouncementIfNeeded(
    sourceLabel: String?,
    sessionID: String?,
    sessionName: String?,
    speed: String,
    volume: String,
    expectedGeneration: StopGenerationSnapshot
) -> Bool {
    guard stopGenerationStore.isCurrent(expectedGeneration) else { return false }
    let mode = currentCueMode()
    guard mode != "off",
          let key = playbackSessionKey(sourceLabel: sourceLabel, sessionID: sessionID) else { return true }
    if currentCueFrequency() == "change" && key == lastAudiblyPlayedSessionKey {
        return true
    }

    let normalizedName = normalizeSessionID(sessionName)
    let normalizedSource = normalizeSourceLabel(sourceLabel)
    let announcement: String?
    switch mode {
    case "source":
        announcement = normalizedSource
    case "both":
        announcement = [normalizedName, normalizedSource].compactMap { $0 }.joined(separator: ". ")
    default:
        announcement = normalizedName
    }
    guard let announcement, !announcement.isEmpty else { return true }

    let outputBase = "/tmp/claude-tts-session-cue-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
    let synthesis = synthesizeSpeechAudio(
        announcement,
        speed: speed,
        requestedEngine: currentRequestedEngine(),
        openAIVoice: currentOpenAIVoice(),
        outputBasePath: outputBase,
        expectedGeneration: expectedGeneration
    )
    guard synthesis.success, let outputFile = synthesis.outputFile else {
        return stopGenerationStore.isCurrent(expectedGeneration)
    }
    defer { try? FileManager.default.removeItem(atPath: outputFile) }
    guard stopGenerationStore.isCurrent(expectedGeneration),
          !FileManager.default.fileExists(atPath: skipFlag),
          waitWhilePaused(expectedGeneration: expectedGeneration) else { return false }
    let played = playAudioFile(outputFile, volume: volume, expectedGeneration: expectedGeneration)
    guard played, stopGenerationStore.isCurrent(expectedGeneration) else {
        return stopGenerationStore.isCurrent(expectedGeneration)
    }
    debugPrint("SESSION CUE — announced \(announcement)")
    return true
}

func playContext(
    _ context: PlaybackContext,
    startIndex: Int,
    status: String,
    expectedGeneration: StopGenerationSnapshot? = nil
) {
    let playbackGeneration = expectedGeneration ?? stopGenerationStore.snapshot()
    guard stopGenerationStore.isCurrent(playbackGeneration) else { return }
    let sentences = splitSentences(context.text)
    guard !sentences.isEmpty else {
        debugPrint("PLAYBACK — no sentences available for \(status)")
        playChime(expectedGeneration: playbackGeneration)
        return
    }

    let clampedStart = min(max(startIndex, 0), max(sentences.count - 1, 0))

    guard stopGenerationStore.performIfCurrent(playbackGeneration, {
        FileManager.default.createFile(atPath: skipFlag, contents: nil)
        killTTSProcesses()
    }) else { return }

    DispatchQueue.global(qos: .userInitiated).async {
        usleep(300_000)
        guard stopGenerationStore.isCurrent(playbackGeneration) else { return }
        playChime(expectedGeneration: playbackGeneration)

        guard let lockOwner = acquireTTSLock(expectedGeneration: playbackGeneration) else { return }
        guard stopGenerationStore.isCurrent(playbackGeneration) else {
            releaseTTSLock(ownerToken: lockOwner)
            return
        }
        let prepared = stopGenerationStore.performIfCurrent(playbackGeneration) {
            try? FileManager.default.removeItem(atPath: skipFlag)
            persistPlaybackContext(context)
            writePlaybackCursor(clampedStart)
            FileManager.default.createFile(atPath: ttsPlayingFlag, contents: nil)
            writeActiveSegment(preview: playbackPreview(context), status: status)
        }
        guard prepared else {
            releaseTTSLock(ownerToken: lockOwner)
            return
        }

        guard playSessionAnnouncementIfNeeded(
            sourceLabel: context.sourceLabel,
            sessionID: context.sessionID,
            sessionName: context.sessionName,
            speed: context.speed,
            volume: context.volume,
            expectedGeneration: playbackGeneration
        ) else {
            releaseTTSLock(ownerToken: lockOwner)
            return
        }

        speakText(
            context.text,
            speed: context.speed,
            volume: context.volume,
            sourceLabel: context.sourceLabel,
            sessionID: context.sessionID,
            startIndex: clampedStart,
            playbackItemID: context.itemID,
            expectedGeneration: playbackGeneration
        )

        _ = stopGenerationStore.performIfCurrent(playbackGeneration) {
            clearTTYSubtitle()
            try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
            try? FileManager.default.removeItem(atPath: skipFlag)
            clearActiveSegment()
        }
        releaseTTSLock(ownerToken: lockOwner)
    }
}

func triggerSentenceSeek(delta: Int) {
    stopGenerationStore.clearAutoplayHold()
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
    stopGenerationStore.clearAutoplayHold()
    debugPrint("REPEAT — replaying current message from start")

    guard let context = loadReplayContext() else {
        debugPrint("REPEAT — no saved text at all, ignoring")
        playChime()
        return
    }

    playContext(context, startIndex: 0, status: "repeat")
}

func triggerRepeatShortcut() {
    let hasActiveRepeatContext =
        FileManager.default.fileExists(atPath: ttsPlayingFlag) ||
        FileManager.default.fileExists(atPath: pauseFlag) ||
        state.isPaused

    if hasActiveRepeatContext {
        debugPrint("REPEAT SHORTCUT — active playback, using repeat context")
        triggerRepeat()
        return
    }

    debugPrint("REPEAT SHORTCUT — idle, continuing playback-log timeline")
    if triggerPlaybackLogAction(timeline: true, status: "repeat") {
        return
    }

    debugPrint("REPEAT SHORTCUT — no playback-log item, falling back to saved repeat context")
    if let context = loadReplayContext() {
        playContext(context, startIndex: 0, status: "repeat")
        return
    }

    debugPrint("REPEAT SHORTCUT — no repeat or replay target")
    playChime()
}

// Shared text-to-speech function — speaks sentence by sentence with skip/forward/rewind support
func speakText(
    _ text: String,
    speed: String,
    volume: String,
    sourceLabel: String? = nil,
    sessionID: String? = nil,
    startIndex: Int = 0,
    queueRestartAware: Bool = false,
    playbackItemID: String? = nil,
    sentenceBaseIndex: Int = 0,
    expectedGeneration: StopGenerationSnapshot? = nil
) {
    let playbackGeneration = expectedGeneration ?? stopGenerationStore.snapshot()
    guard stopGenerationStore.isCurrent(playbackGeneration) else { return }
    let sentences = splitSentences(text)
    guard !sentences.isEmpty else { return }

    let normalizedSource = normalizeSourceLabel(sourceLabel)
    let normalizedSession = normalizeSessionID(sessionID)

    var idx = min(max(startIndex, 0), max(sentences.count - 1, 0))
    var startedAudiblePlayback = false
    while idx < sentences.count {
        guard stopGenerationStore.isCurrent(playbackGeneration) else { break }
        if FileManager.default.fileExists(atPath: skipFlag) { break }
        if queueRestartAware && shouldRestartQueuePlayback() {
            debugPrint("QUEUE — restart requested during active playback")
            break
        }
        if !waitWhilePaused(expectedGeneration: playbackGeneration) { break }

        // Check forward/rewind
        if FileManager.default.fileExists(atPath: forwardFlag) {
            guard stopGenerationStore.performIfCurrent(playbackGeneration, {
                try? FileManager.default.removeItem(atPath: forwardFlag)
                killTTSProcesses()
            }) else { break }
            idx = min(idx + 1, sentences.count - 1)
            continue
        }
        if FileManager.default.fileExists(atPath: rewindFlag) {
            guard stopGenerationStore.performIfCurrent(playbackGeneration, {
                try? FileManager.default.removeItem(atPath: rewindFlag)
                killTTSProcesses()
            }) else { break }
            idx = max(idx - 1, 0)
            continue
        }

        let sentence = sentences[idx]
        let subtitleText: String
        let spokenText: String

        if let source = normalizedSource {
            subtitleText = "[\(source)] \(sentence)"
            spokenText = sentence
        } else {
            subtitleText = sentence
            spokenText = sentence
        }

        let outputFile: String
        let shouldRemoveAfterPlayback: Bool
        let cacheSentenceIndex = sentenceBaseIndex + idx
        guard stopGenerationStore.performIfCurrent(playbackGeneration, {
            showTTYSubtitle(subtitleText)
            writePlaybackCursor(cacheSentenceIndex)
        }) else { break }
        if let playbackItemID,
           let cachedPath = cachedSentenceAudioPath(itemID: playbackItemID, sentenceIndex: cacheSentenceIndex) {
            outputFile = cachedPath
            shouldRemoveAfterPlayback = false
        } else {
            let outputBasePath: String
            let requestedEngine: String
            if let playbackItemID,
               let item = findPlaybackLogItem(id: playbackItemID) {
                outputBasePath = "\(item.itemDir)/audio/\(String(format: "%03d", cacheSentenceIndex + 1))"
                requestedEngine = item.engine
            } else {
                outputBasePath = "/tmp/claude-tts-repeat-\(ProcessInfo.processInfo.processIdentifier)-\(idx + 1)"
                requestedEngine = currentRequestedEngine()
            }

            let synthesis = synthesizeSpeechAudio(
                spokenText,
                speed: speed,
                requestedEngine: requestedEngine,
                openAIVoice: currentOpenAIVoice(),
                outputBasePath: outputBasePath,
                expectedGeneration: playbackGeneration
            )
            guard synthesis.success, let synthesizedFile = synthesis.outputFile else {
                guard stopGenerationStore.isCurrent(playbackGeneration) else { break }
                debugPrint("TTS — synthesis failed for sentence \(idx + 1)")
                if queueRestartAware && shouldRestartQueuePlayback() {
                    break
                }
                idx += 1
                continue
            }
            outputFile = synthesizedFile
            shouldRemoveAfterPlayback = playbackItemID == nil

            if let playbackItemID {
                _ = stopGenerationStore.performIfCurrent(playbackGeneration) {
                    updatePlaybackLogAudioState(
                        itemID: playbackItemID,
                        sentenceIndex: cacheSentenceIndex,
                        audioFile: synthesizedFile,
                        actualEngine: synthesis.actualEngine,
                        fallbackReason: synthesis.fallbackReason
                    )
                }
            }
        }

        if !stopGenerationStore.isCurrent(playbackGeneration) || FileManager.default.fileExists(atPath: skipFlag) {
            if shouldRemoveAfterPlayback {
                try? FileManager.default.removeItem(atPath: outputFile)
            }
            break
        }
        if queueRestartAware && shouldRestartQueuePlayback() {
            if shouldRemoveAfterPlayback {
                try? FileManager.default.removeItem(atPath: outputFile)
            }
            break
        }
        if !waitWhilePaused(expectedGeneration: playbackGeneration) {
            if shouldRemoveAfterPlayback {
                try? FileManager.default.removeItem(atPath: outputFile)
            }
            break
        }

        // Play audio
        let played = playAudioFile(
            outputFile,
            volume: volume,
            expectedGeneration: playbackGeneration,
            onStarted: {
                if !startedAudiblePlayback {
                    noteAudiblePlayback(sourceLabel: normalizedSource, sessionID: normalizedSession)
                    startedAudiblePlayback = true
                }
            }
        )

        if shouldRemoveAfterPlayback {
            try? FileManager.default.removeItem(atPath: outputFile)
        }
        if !played {
            debugPrint("TTS — afplay failed for sentence \(idx + 1)")
            if queueRestartAware && shouldRestartQueuePlayback() {
                break
            }
            idx += 1
            continue
        }
        guard stopGenerationStore.isCurrent(playbackGeneration) else { break }
        if FileManager.default.fileExists(atPath: skipFlag) { break }
        if queueRestartAware && shouldRestartQueuePlayback() {
            break
        }
        if FileManager.default.fileExists(atPath: forwardFlag) || FileManager.default.fileExists(atPath: rewindFlag) {
            continue
        }
        guard stopGenerationStore.performIfCurrent(playbackGeneration, {
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
            writePlaybackCursor(cacheSentenceIndex + 1)
        }) else { break }
        idx += 1
    }
    if let playbackItemID, startedAudiblePlayback {
        _ = stopGenerationStore.performIfCurrent(playbackGeneration) {
            markPlaybackLogItemPlayback(id: playbackItemID, completed: idx >= sentences.count)
        }
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

// MARK: - Drill-Down (ctrl+shift double-tap or voice keyword)

func triggerDrillDown(target: String? = nil) {
    stopGenerationStore.clearAutoplayHold()
    let playbackGeneration = stopGenerationStore.snapshot()
    DispatchQueue.global(qos: .userInitiated).async {
        performDrillDown(target: target, playbackGeneration: playbackGeneration)
    }
}

func performDrillDown(
    target: String?,
    playbackGeneration: StopGenerationSnapshot
) {
    guard stopGenerationStore.isCurrent(playbackGeneration) else { return }
    debugPrint("DRILL-DOWN — target: \(target ?? "cycle")")

    // Read available cache entries from index
    guard let indexContent = try? String(contentsOfFile: detailIndexFile, encoding: .utf8) else {
        debugPrint("DRILL-DOWN — no index file, ignoring")
        playChime(expectedGeneration: playbackGeneration)
        return
    }

    let entries = indexContent.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !entries.isEmpty else {
        debugPrint("DRILL-DOWN — index empty, ignoring")
        playChime(expectedGeneration: playbackGeneration)
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
                playChime(expectedGeneration: playbackGeneration)
                return
            }
        }
    } else {
        // Cycle mode — read current drill index, advance
        let currentStr = (try? String(contentsOfFile: drillDownIndexFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "-1"
        var current = Int(currentStr) ?? -1
        current = (current + 1) % entries.count
        guard stopGenerationStore.performIfCurrent(playbackGeneration, {
            try? "\(current)".write(toFile: drillDownIndexFile, atomically: true, encoding: .utf8)
        }) else { return }
        entryFile = entries[current]
        debugPrint("DRILL-DOWN — cycling to entry \(current + 1)/\(entries.count): \(entryFile)")
    }

    // Stop any active audio
    guard stopGenerationStore.performIfCurrent(playbackGeneration, {
        FileManager.default.createFile(atPath: skipFlag, contents: nil)
        killTTSProcesses()
    }) else { return }
    usleep(300_000)

    guard let lockOwner = acquireTTSLock(expectedGeneration: playbackGeneration) else { return }
    guard stopGenerationStore.isCurrent(playbackGeneration) else {
        releaseTTSLock(ownerToken: lockOwner)
        return
    }
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
    let previewText = String((try? String(contentsOfFile: "\(detailCacheDir)/\(entriesToPlay[0])", encoding: .utf8))?.prefix(60) ?? "")
    guard stopGenerationStore.performIfCurrent(playbackGeneration, {
        try? FileManager.default.removeItem(atPath: skipFlag)
        FileManager.default.createFile(atPath: ttsPlayingFlag, contents: nil)
        writeActiveSegment(preview: previewText, status: "drill-down")
    }) else {
        releaseTTSLock(ownerToken: lockOwner)
        return
    }
    playDoubleTink(expectedGeneration: playbackGeneration)

    // Play in background
    DispatchQueue.global(qos: .userInitiated).async {
        for entry in entriesToPlay {
            guard stopGenerationStore.isCurrent(playbackGeneration) else { break }
            let filePath = "\(detailCacheDir)/\(entry)"
            guard let text = try? String(contentsOfFile: filePath, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                debugPrint("DRILL-DOWN — empty or missing file: \(filePath)")
                continue
            }

            // Save for repeat
            guard stopGenerationStore.performIfCurrent(playbackGeneration, {
                try? text.write(toFile: lastTextFile, atomically: true, encoding: .utf8)
                try? speed.write(toFile: lastSpeedFile, atomically: true, encoding: .utf8)
                try? volume.write(toFile: lastVolumeFile, atomically: true, encoding: .utf8)
            }) else { break }

            let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var skipped = false
            var idx = 0
            while idx < sentences.count {
                guard stopGenerationStore.isCurrent(playbackGeneration) else { skipped = true; break }
                if FileManager.default.fileExists(atPath: skipFlag) { skipped = true; break }

                // Check forward/rewind
                if FileManager.default.fileExists(atPath: forwardFlag) {
                    guard stopGenerationStore.performIfCurrent(playbackGeneration, {
                        try? FileManager.default.removeItem(atPath: forwardFlag)
                        killTTSProcesses()
                    }) else { skipped = true; break }
                    idx = min(idx + 3, sentences.count - 1)
                    continue
                }
                if FileManager.default.fileExists(atPath: rewindFlag) {
                    guard stopGenerationStore.performIfCurrent(playbackGeneration, {
                        try? FileManager.default.removeItem(atPath: rewindFlag)
                        killTTSProcesses()
                    }) else { skipped = true; break }
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
                let generated = runProcessWithTimeout(
                    sayProc,
                    timeout: 15,
                    expectedGeneration: playbackGeneration
                )

                if !generated || !stopGenerationStore.isCurrent(playbackGeneration) || FileManager.default.fileExists(atPath: skipFlag) {
                    try? FileManager.default.removeItem(atPath: tmpFile)
                    skipped = true
                    break
                }

                // Play audio
                _ = playAudioFile(
                    tmpFile,
                    volume: volume,
                    expectedGeneration: playbackGeneration
                )

                try? FileManager.default.removeItem(atPath: tmpFile)
                idx += 1
            }

            if skipped { break }
        }

        // Cleanup
        _ = stopGenerationStore.performIfCurrent(playbackGeneration) {
            try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
            try? FileManager.default.removeItem(atPath: skipFlag)
            clearActiveSegment()
        }
        releaseTTSLock(ownerToken: lockOwner)
    }
}

// MARK: - Message Navigation (ctrl+shift+arrow)

func interruptPlaybackForReplay() {
    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    killTTSProcesses()
    try? FileManager.default.removeItem(atPath: ttsPlayingFlag)
}

func waitForPlaybackLockRelease(
    expectedGeneration: StopGenerationSnapshot,
    maxTicks: Int = 30
) -> Bool {
    var waited = 0
    while FileManager.default.fileExists(atPath: ttsLockDir) && waited < maxTicks {
        guard stopGenerationStore.isCurrent(expectedGeneration) else { return false }
        if let pidStr = try? String(contentsOfFile: ttsLockPidFile, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) != 0 {
            _ = stopGenerationStore.performIfCurrent(expectedGeneration) {
                let currentPid = try? String(contentsOfFile: ttsLockPidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if currentPid == String(pid) {
                    try? FileManager.default.removeItem(atPath: ttsLockDir)
                }
            }
            break
        }
        usleep(100_000)
        waited += 1
    }
    if FileManager.default.fileExists(atPath: ttsLockDir) {
        guard stopGenerationStore.isCurrent(expectedGeneration) else { return false }
        debugPrint("TTS lock wait timed out; live owner retained")
        return false
    }
    return stopGenerationStore.isCurrent(expectedGeneration)
}

func playbackLogTargetItem(direction: String? = nil, useLatest: Bool = false) -> PlaybackLogItem? {
    var items = focusedPlaybackLogItems()
    guard !items.isEmpty else { return nil }

    if useLatest {
        let latest = items.last
        writeCurrentPlaybackItemID(latest?.id)
        return latest
    }

    let defaultIndex = max(items.count - 1, 0)
    let currentIndex: Int
    if direction != nil,
       let anchorID = readBackfillNavigationAnchor(),
       let anchor = items.first(where: { $0.id == anchorID }) {
        items = items.filter {
            $0.sourceLabel == anchor.sourceLabel && $0.sessionID == anchor.sessionID
        }
        currentIndex = items.firstIndex(where: { $0.id == anchorID }) ?? max(items.count - 1, 0)
        try? FileManager.default.removeItem(atPath: backfillNavigationAnchorFile)
    } else if direction != nil,
              let currentID = readCurrentPlaybackItemID(),
              let current = items.first(where: { $0.id == currentID }) {
        items = items.filter {
            $0.sourceLabel == current.sourceLabel && $0.sessionID == current.sessionID
        }
        currentIndex = items.firstIndex(where: { $0.id == currentID }) ?? max(items.count - 1, 0)
    } else if let currentID = readCurrentPlaybackItemID(),
              let idx = items.firstIndex(where: { $0.id == currentID }) {
        currentIndex = idx
    } else {
        currentIndex = defaultIndex
    }

    guard let targetIndex = playbackLogTargetIndex(
        itemCount: items.count,
        currentIndex: currentIndex,
        direction: direction
    ) else { return nil }

    let target = items[targetIndex]
    writeCurrentPlaybackItemID(target.id)
    return target
}

@discardableResult
func triggerPlaybackLogAction(
    direction: String? = nil,
    useLatest: Bool = false,
    useFirst: Bool = false,
    timeline: Bool = false,
    status: String
) -> Bool {
    stopGenerationStore.clearAutoplayHold()
    let playbackGeneration = stopGenerationStore.snapshot()
    let targetItem: PlaybackLogItem?
    if useFirst {
        targetItem = playbackLogFirstItem()
    } else if timeline {
        targetItem = playbackLogTimelineItem()
    } else {
        targetItem = playbackLogTargetItem(direction: direction, useLatest: useLatest)
    }

    guard let target = targetItem,
          let context = playbackContext(from: target) else {
        if !stopGenerationStore.hasRecordedStop(), triggerHistoryPlaybackAction(
            direction: direction,
            useFirst: useFirst,
            useLatest: useLatest,
            timeline: timeline,
            status: status,
            expectedGeneration: playbackGeneration
        ) {
            return true
        }
        playChime(expectedGeneration: playbackGeneration)
        return false
    }

    interruptPlaybackForReplay()

    DispatchQueue.global(qos: .userInitiated).async {
        guard waitForPlaybackLockRelease(expectedGeneration: playbackGeneration) else { return }
        debugPrint("PLAYBACK LOG — playing \(target.id) status=\(status)")
        playContext(
            context,
            startIndex: 0,
            status: status,
            expectedGeneration: playbackGeneration
        )
    }

    return true
}

func handlePlaybackLogCommandIfNeeded() {
    guard let command = try? String(contentsOfFile: playbackLogCommandFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !command.isEmpty else {
        return
    }

    try? FileManager.default.removeItem(atPath: playbackLogCommandFile)

    switch command {
    case "play", "timeline":
        _ = triggerPlaybackLogAction(timeline: true, status: "nav")
    case "first", "oldest":
        _ = triggerPlaybackLogAction(useFirst: true, status: "nav")
    case "back":
        _ = triggerPlaybackLogAction(direction: "prev", status: "nav")
    case "next":
        _ = triggerPlaybackLogAction(direction: "next", status: "nav")
    case "replay":
        _ = triggerPlaybackLogAction(status: "repeat")
    case "latest":
        _ = triggerPlaybackLogAction(useLatest: true, status: "nav")
    default:
        debugPrint("PLAYBACK LOG — unknown command \(command)")
    }
}

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

    if triggerPlaybackLogAction(direction: direction == "next" ? "next" : "prev", status: "nav") {
        return
    }
    if stopGenerationStore.hasRecordedStop() {
        debugPrint("MESSAGE NAV — no playback-log target after stop; legacy history fallback suppressed")
        playChime()
        return
    }
    let playbackGeneration = stopGenerationStore.snapshot()

    // Signal auto-speak.sh to stop and kill audio
    FileManager.default.createFile(atPath: skipFlag, contents: nil)
    killTTSProcesses()
    try? FileManager.default.removeItem(atPath: ttsPlayingFlag)

    // Everything on background thread — main thread must stay free for CGEvent
    DispatchQueue.global(qos: .userInitiated).async {
        guard waitForPlaybackLockRelease(expectedGeneration: playbackGeneration) else { return }

        // Chime immediately — audio is dead
        playChime(expectedGeneration: playbackGeneration)
        // Brief wait then kill any straggler say processes (not afplay so chime survives)
        usleep(200_000)
        guard stopGenerationStore.isCurrent(playbackGeneration) else { return }
        let killSay = Process()
        killSay.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killSay.arguments = ["say"]
        _ = runProcessWithTimeout(
            killSay,
            timeout: 3,
            expectedGeneration: playbackGeneration
        )
        guard stopGenerationStore.isCurrent(playbackGeneration) else { return }
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
                guard current < totalHistory - 1 else {
                    playChime(expectedGeneration: playbackGeneration)
                    return
                }
                current += 1
            } else {
                guard current > 0 else {
                    playChime(expectedGeneration: playbackGeneration)
                    return
                }
                current -= 1
            }

            let historyIndex = current + 1
            guard let context = readHistoryMessage(at: historyIndex) else {
                debugPrint("MESSAGE NAV — missing history message \(historyIndex)")
                playChime(expectedGeneration: playbackGeneration)
                return
            }

            guard stopGenerationStore.performIfCurrent(playbackGeneration, {
                try? "\(current)".write(toFile: navIndexFile, atomically: true, encoding: .utf8)
                try? "\(historyIndex)".write(toFile: repeatAnchorFile, atomically: true, encoding: .utf8)
            }) else { return }
            debugPrint("MESSAGE NAV — updated repeat anchor to \(historyIndex)")
            debugPrint("MESSAGE NAV — playing history \(historyIndex)/\(totalHistory)")

            playContext(
                context,
                startIndex: 0,
                status: "nav",
                expectedGeneration: playbackGeneration
            )
            return
        }

        debugPrint("MESSAGE NAV — no session history, falling back to transcript")
        let messages = extractMessagesFromTranscript()
        let total = messages.count
        debugPrint("MESSAGE NAV — found \(total) transcript messages")

        guard total > 0 else {
            debugPrint("MESSAGE NAV — no transcript messages, playing boundary chime")
            playChime(expectedGeneration: playbackGeneration)
            return
        }

        let currentStr = (try? String(contentsOfFile: navIndexFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "\(total - 1)"
        var current = Int(currentStr) ?? (total - 1)
        current = min(max(current, 0), total - 1)

        if direction == "next" {
            guard current < total - 1 else {
                playChime(expectedGeneration: playbackGeneration)
                return
            }
            current += 1
        } else {
            guard current > 0 else {
                playChime(expectedGeneration: playbackGeneration)
                return
            }
            current -= 1
        }

        guard stopGenerationStore.performIfCurrent(playbackGeneration, {
            try? "\(current)".write(toFile: navIndexFile, atomically: true, encoding: .utf8)
        }) else { return }
        let context: PlaybackContext = (
            text: messages[current],
            speed: currentSpeechSpeed(),
            volume: "1.0",
            sourceLabel: nil,
            sessionID: nil,
            sessionName: nil,
            itemID: nil
        )
        debugPrint("MESSAGE NAV — playing transcript \(current + 1)/\(total)")
        playContext(
            context,
            startIndex: 0,
            status: "nav",
            expectedGeneration: playbackGeneration
        )
    }
}

// MARK: - Queue Processing (daemon speaks queued messages from auto-speak.sh)

func processQueue() {
    guard !state.isProcessingQueue else { return }
    archivePendingQueueEntries(discardStaging: false, onlyHeldEntries: true)
    guard !stopGenerationStore.isAutoplayHeld() else { return }
    let queueGeneration = stopGenerationStore.snapshot()
    state.isProcessingQueue = true

    DispatchQueue.global(qos: .userInitiated).async {
        defer { state.isProcessingQueue = false }

        let fm = FileManager.default
        ensureDirectory(queueDir)

        guard let lockOwner = acquireTTSLock(expectedGeneration: queueGeneration) else { return }
        guard stopGenerationStore.isCurrent(queueGeneration) else {
            releaseTTSLock(ownerToken: lockOwner)
            return
        }
        guard stopGenerationStore.performIfCurrent(queueGeneration, {
            fm.createFile(atPath: ttsPlayingFlag, contents: nil)
        }) else {
            releaseTTSLock(ownerToken: lockOwner)
            return
        }

        while true {
            guard stopGenerationStore.isCurrent(queueGeneration) else { break }
            let target = currentTargetScope()
            restoreDeferredEntriesIfNeeded(target: target)
            guard let entries = try? fm.contentsOfDirectory(atPath: queueDir).sorted() else { break }
            let queueEntries = prioritizeQueueEntries(
                entries.filter { $0.hasPrefix("entry-") },
                in: queueDir
            )

            guard !queueEntries.isEmpty else { break }
            let entry = queueEntries[0]
            let entryPath = "\(queueDir)/\(entry)"
            // Check skip flag — if set, clear remaining queue
            if fm.fileExists(atPath: skipFlag) {
                debugPrint("QUEUE — skip flag detected, clearing remaining entries")
                // Remove matching-target entries only. Preserve out-of-scope audio
                // so target=claude does not delete pending Codex items, and inverse.
                for remaining in queueEntries {
                    let remainingPath = "\(queueDir)/\(remaining)"
                    let remainingSource = normalizeSourceLabel(
                        try? String(contentsOfFile: "\(remainingPath)/source", encoding: .utf8)
                    )
                    if sourceMatchesTarget(remainingSource, target: target) {
                        let entryURL = URL(fileURLWithPath: remainingPath)
                        if archiveQueueEntryThenRemove(
                            entryURL,
                            archive: archiveQueueEntryToPlaybackLog
                        ) == nil {
                            debugPrint("QUEUE — WARNING: skip archival failed; retaining \(remainingPath)")
                        }
                    } else if targetDropNonmatchingEnabled() {
                        debugPrint("QUEUE — dropping nonmatching skip entry target=\(target) source=\(remainingSource ?? "unknown")")
                        let entryURL = URL(fileURLWithPath: remainingPath)
                        if archiveQueueEntryThenRemove(
                            entryURL,
                            archive: archiveQueueEntryToPlaybackLog
                        ) == nil {
                            debugPrint("QUEUE — WARNING: nonmatching skip archival failed; retaining \(remainingPath)")
                        }
                    } else {
                        deferQueueEntry(
                            entryPath: remainingPath,
                            entryName: remaining,
                            sourceLabel: remainingSource,
                            target: target
                        )
                    }
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
            let sessionName = normalizeSessionID(try? String(contentsOfFile: "\(entryPath)/session_name", encoding: .utf8))
            let blockID = normalizeSessionID(try? String(contentsOfFile: "\(entryPath)/block", encoding: .utf8))
            let rawText = (try? String(contentsOfFile: "\(entryPath)/raw", encoding: .utf8))
                ?? text
            let normalizedText = (try? String(contentsOfFile: "\(entryPath)/normalized", encoding: .utf8))
                ?? text
            let metadata = readQueueItemMetadata(at: "\(entryPath)/meta.json")
            let effectiveSpeed = currentSpeechSpeed(fallback: speed)
            if !sourceMatchesTarget(sourceLabel, target: target) {
                if targetDropNonmatchingEnabled() {
                    debugPrint("QUEUE — dropping nonmatching entry target=\(target) source=\(sourceLabel ?? "unknown")")
                    try? fm.removeItem(atPath: entryPath)
                } else {
                    deferQueueEntry(entryPath: entryPath, entryName: entry, sourceLabel: sourceLabel, target: target)
                }
                continue
            }
            let previewBase = String(text.prefix(60))
            let previewText = sourceLabel != nil ? "[\(sourceLabel!)] \(previewBase)" : previewBase
            guard let logResult = stopGenerationStore.valueIfCurrent(queueGeneration, {
                writeActiveSegment(
                    segment: 1,
                    total: queueEntries.count,
                    preview: previewText,
                    status: queueStatusLabel(base: "speaking")
                )
                try? effectiveSpeed.write(toFile: lastSpeedFile, atomically: true, encoding: .utf8)
                let result = upsertPlaybackLogItem(
                    blockID: blockID,
                    rawText: rawText,
                    normalizedText: normalizedText,
                    sourceLabel: sourceLabel,
                    sessionID: sessionID,
                    sessionName: sessionName,
                    speed: effectiveSpeed,
                    volume: volume,
                    metadata: metadata
                )
                writeCurrentPlaybackItemID(result.item.id)
                writeString(result.item.id, to: "\(entryPath)/playback-item-id")
                return result
            }) else { break }
            debugPrint("QUEUE — speaking next entry (remaining \(queueEntries.count))")

            let liveText = (logResult.newSentenceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? logResult.newSentenceText!
                : text
            guard playSessionAnnouncementIfNeeded(
                sourceLabel: sourceLabel,
                sessionID: sessionID,
                sessionName: sessionName,
                speed: effectiveSpeed,
                volume: volume,
                expectedGeneration: queueGeneration
            ) else { break }
            speakText(
                liveText,
                speed: effectiveSpeed,
                volume: volume,
                sourceLabel: sourceLabel,
                sessionID: sessionID,
                queueRestartAware: true,
                playbackItemID: logResult.newSentenceText == nil ? nil : logResult.item.id,
                sentenceBaseIndex: logResult.newSentenceText == nil ? 0 : logResult.sentenceOffset,
                expectedGeneration: queueGeneration
            )

            guard stopGenerationStore.isCurrent(queueGeneration) else { break }
            if fm.fileExists(atPath: restartQueueFlag) {
                debugPrint("QUEUE — restart requested, keeping current entry and reprioritizing")
                try? fm.removeItem(atPath: restartQueueFlag)
                continue
            }

            // Remove processed entry
            try? fm.removeItem(atPath: entryPath)
        }

        // Cleanup
        _ = stopGenerationStore.performIfCurrent(queueGeneration) {
            clearTTYSubtitle()
            try? fm.removeItem(atPath: ttsPlayingFlag)
            try? fm.removeItem(atPath: skipFlag)
            try? fm.removeItem(atPath: restartQueueFlag)
            clearActiveSegment()
        }
        releaseTTSLock(ownerToken: lockOwner)
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
            let hasAlternate = flags.contains(.maskAlternate)
            let hasShift = flags.contains(.maskShift)
            let hasCommand = flags.contains(.maskCommand)
            let hasControl = flags.contains(.maskControl)

            if hasControl && !hasShift && !hasCommand && !hasAlternate && (keyCode == upArrowKeyCode || keyCode == downArrowKeyCode) {
                markControlComboUse()
                if keyCode == upArrowKeyCode {
                    debugPrint("CTRL+UP — increase speed")
                    DispatchQueue.main.async { adjustSpeechSpeed(delta: speechSpeedStep) }
                } else {
                    debugPrint("CTRL+DOWN — decrease speed")
                    DispatchQueue.main.async { adjustSpeechSpeed(delta: -speechSpeedStep) }
                }
                return Unmanaged.passUnretained(event)
            }

            // ctrl+shift+arrow: during file read = 20-line skip, otherwise = message nav
            if hasControl && hasShift && !hasCommand && !hasAlternate && (keyCode == leftArrowKeyCode || keyCode == rightArrowKeyCode) {
                markControlComboUse()
                if isReadingFile() {
                    // File read active — skip 20 lines forward/back
                    if keyCode == rightArrowKeyCode {
                        debugPrint("CTRL+SHIFT+RIGHT — big forward 20 lines (file read)")
                        FileManager.default.createFile(atPath: bigForwardFlag, contents: nil)
                    } else {
                        debugPrint("CTRL+SHIFT+LEFT — big rewind 20 lines (file read)")
                        FileManager.default.createFile(atPath: bigRewindFlag, contents: nil)
                    }
                    killTTSProcesses()
                    usleep(100_000)
                    playChime()
                } else {
                    // Terminal mode — message navigation
                    let direction = (keyCode == rightArrowKeyCode) ? "next" : "prev"
                    debugPrint("CTRL+SHIFT+ARROW — message nav \(direction)")
                    DispatchQueue.main.async { triggerMessageNav(direction: direction) }
                }
                return Unmanaged.passUnretained(event)
            }

            // ctrl+arrow: forward/rewind. While speaking, seek within the active playback.
            // When idle, move through the playback log instead.
            if hasControl && !hasShift && !hasCommand && !hasAlternate && (keyCode == leftArrowKeyCode || keyCode == rightArrowKeyCode) {
                markControlComboUse()
                if keyCode == rightArrowKeyCode {
                    if isTTSPlaying() {
                        debugPrint("CTRL+RIGHT — forward 1 sentence")
                        FileManager.default.createFile(atPath: forwardFlag, contents: nil)
                        killTTSProcesses()
                        usleep(100_000)
                        playChime()
                    } else {
                        debugPrint("CTRL+RIGHT — playback log next")
                        DispatchQueue.main.async {
                            _ = triggerPlaybackLogAction(direction: "next", status: "nav")
                        }
                    }
                } else {
                    if isTTSPlaying() {
                        debugPrint("CTRL+LEFT — rewind 1 sentence")
                        FileManager.default.createFile(atPath: rewindFlag, contents: nil)
                        killTTSProcesses()
                        usleep(100_000)
                        playChime()
                    } else {
                        debugPrint("CTRL+LEFT — playback log previous")
                        DispatchQueue.main.async {
                            _ = triggerPlaybackLogAction(direction: "prev", status: "nav")
                        }
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
    // Control keys: 59 (left), 62 (right)
    let isControlKey = (keyCode == 59 || keyCode == 62)
    // Shift keys: 56 (left), 60 (right)
    let isShiftKey = (keyCode == 56 || keyCode == 60)
    // Function key: 63 on Apple keyboards
    let isFunctionKey = (keyCode == functionKeyCode || flags.contains(.maskSecondaryFn))

    if !isCommandKey && !isControlKey && !isShiftKey && !isFunctionKey {
        return Unmanaged.passUnretained(event)
    }

    // --- FUNCTION DOUBLE-TAP: PLAY NEXT LOG ITEM ---
    if isFunctionKey {
        let hasFunction = flags.contains(.maskSecondaryFn)
        let hasOtherModifier = !flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty

        if hasOtherModifier {
            state.functionIsDown = false
            state.lastFunctionUp = nil
            return Unmanaged.passUnretained(event)
        }

        debugPrint("Function flagsChanged: keyCode=\(keyCode) hasFunction=\(hasFunction)")

        if hasFunction && !state.functionIsDown {
            state.functionIsDown = true
        } else if !hasFunction && state.functionIsDown {
            state.functionIsDown = false
            let now = Date()

            if let last = state.lastFunctionUp, now.timeIntervalSince(last) < doubleTapWindow {
                state.lastFunctionUp = nil
                debugPrint("FUNCTION DOUBLE TAP — playback log timeline")
                DispatchQueue.main.async {
                    _ = triggerPlaybackLogAction(timeline: true, status: "nav")
                }
            } else {
                state.lastFunctionUp = now
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // --- CTRL+SHIFT DOUBLE-TAP: DRILL-DOWN ---
    // Detect ctrl+shift held together then released twice. Does NOT interfere
    // with ctrl+shift+arrow (that's a keyDown event, this is flagsChanged).
    if isControlKey || isShiftKey {
        let hasAlternate = flags.contains(.maskAlternate)
        let hasShift = flags.contains(.maskShift)
        let hasCommand = flags.contains(.maskCommand)
        let hasControl = flags.contains(.maskControl)

        // When both ctrl+shift are pressed (and no cmd/alternate)
        if hasControl && hasShift && !hasCommand && !hasAlternate {
            if !state.controlShiftTriggered {
                state.controlShiftTriggered = true
                debugPrint("CTRL+SHIFT down — armed for drill-down")
            }
        }

        // When all modifiers released (keys release one at a time, so this fires
        // on the SECOND release — e.g., ctrl releases, then shift releases)
        if state.controlShiftTriggered && !hasAlternate && !hasShift && !hasCommand && !hasControl {
            state.controlShiftTriggered = false
            let now = Date()
            state.lastControlComboUse = now

            if let last = state.lastControlShiftUp, now.timeIntervalSince(last) < doubleTapWindow {
                state.lastControlShiftUp = nil
                debugPrint("CTRL+SHIFT DOUBLE TAP — triggering drill-down")
                playChime()
                DispatchQueue.main.async { triggerDrillDown() }
            } else {
                state.lastControlShiftUp = now
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
        let hasAlternate = flags.contains(.maskAlternate)

        // When both cmd+shift are pressed (and no ctrl/alternate)
        if hasCommand && hasShift && !hasControl && !hasAlternate {
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
                DispatchQueue.main.async { triggerRepeatShortcut() }
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

    // --- CONTROL DOUBLE-TAP: PAUSE/RESUME ---
    if isControlKey {
        let hasControl = flags.contains(.maskControl)

        // Ignore if other modifiers held
        if !flags.intersection([.maskShift, .maskAlternate, .maskCommand]).isEmpty {
            state.controlIsDown = false
            state.lastControlUp = nil
            return Unmanaged.passUnretained(event)
        }

        debugPrint("Control flagsChanged: keyCode=\(keyCode) hasControl=\(hasControl)")

        if hasControl && !state.controlIsDown {
            state.controlIsDown = true
        } else if !hasControl && state.controlIsDown {
            state.controlIsDown = false
            let now = Date()

            if let lastCombo = state.lastControlComboUse, now.timeIntervalSince(lastCombo) < doubleTapWindow {
                debugPrint("CONTROL DOUBLE TAP — suppressed after control-based combo")
                state.lastControlUp = nil
                return Unmanaged.passUnretained(event)
            }

            if let last = state.lastControlUp, now.timeIntervalSince(last) < doubleTapWindow {
                state.lastControlUp = nil
                // Always allow pause toggle — if user double-taps ctrl, they want to pause/resume.
                // Checking isVoiceActive() was too strict: the flag can be cleared between sentences.
                debugPrint("CONTROL DOUBLE TAP — toggling pause")
                DispatchQueue.main.async { togglePause() }
            } else {
                state.lastControlUp = now
            }
        }
    }

    // --- SHIFT DOUBLE-TAP: STOP ALL ---
    if isShiftKey {
        let hasShift = flags.contains(.maskShift)

        // Only trigger when shift alone (no cmd, alternate, ctrl)
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            state.shiftIsDown = false
            state.lastShiftUp = nil
            return Unmanaged.passUnretained(event)
        }

        // Don't trigger if cmd+shift repeat or ctrl+shift drill-down is armed
        if state.cmdShiftTriggered || state.controlShiftTriggered {
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

_ = prunePlaybackLog()

var configMissCount = 0
var configCheckCounter = 0  // Only check config every 6th tick (6 * 0.3s ≈ 2s)

let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
    if FileManager.default.fileExists(atPath: stopAllRequestFile) {
        try? FileManager.default.removeItem(atPath: stopAllRequestFile)
        triggerStopAll()
    }

    if FileManager.default.fileExists(atPath: autoplayResumeRequestFile) {
        try? FileManager.default.removeItem(atPath: autoplayResumeRequestFile)
        stopGenerationStore.clearAutoplayHold()
    }

    importPendingBackfillBatches()

    // Queue check runs every tick (0.3s) for responsive pickup
    if !state.isProcessingQueue {
        archivePendingQueueEntries(discardStaging: false, onlyHeldEntries: true)
        let hasQueuedEntries: Bool
        if FileManager.default.fileExists(atPath: queueDir),
           let entries = try? FileManager.default.contentsOfDirectory(atPath: queueDir) {
            hasQueuedEntries = entries.contains(where: { $0.hasPrefix("entry-") })
        } else {
            hasQueuedEntries = false
        }

        if hasQueuedEntries || shouldProcessDeferredQueue() {
            processQueue()
        }
    }

    handlePlaybackLogCommandIfNeeded()

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
