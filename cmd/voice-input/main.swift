import Foundation
import CoreGraphics
import AppKit
import Darwin

// Voice input daemon: launches whisper-stream, parses ANSI output, types text
// via CGEvents, detects "send" keyword to submit, handles skip/stop flags.
//
// Usage: voice-input [--model PATH] [--timeout 120] [--debug]

// MARK: - Constants

let whisperStreamPath = "/opt/homebrew/bin/whisper-stream"
let stopFlag = "/tmp/claude-voice-input-stop"
let skipFlag = "/tmp/claude-tts-skip"
let debugLogPath = "/tmp/claude-voice-input-debug.log"
let backspaceKeyCode: CGKeyCode = 51
let enterKeyCode: CGKeyCode = 36
let sendStabilityDelay: TimeInterval = 1.5
let sendingFlag = "/tmp/claude-voice-input-sending"
let voiceConfigPath = "/tmp/claude-voice-config"
let voiceConfigCacheTTL: TimeInterval = 1.0
let matcherActivationDelay: TimeInterval = 0.15

let hallucinationTokens: Set<String> = [
    "[BLANK_AUDIO]", "[MUSIC PLAYING]", "[MUSIC]", "[END PLAYBACK]",
    "[END]", "[SOUND]", "[NOISE]", "[SILENCE]", "[INAUDIBLE]",
    "[Start speaking]"
]

// MARK: - Arguments

let binaryDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
var modelPath = "\(binaryDir)/../models/ggml-small.en.bin"
var timeout: TimeInterval = 120
var debug = false
var cachedVoiceConfig: [String: String] = [:]
var cachedVoiceConfigReadAt = Date.distantPast
var cachedProcessSnapshot: [ProcessSnapshotEntry] = []
var cachedProcessSnapshotReadAt = Date.distantPast

do {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--model"), idx + 1 < args.count {
        modelPath = args[idx + 1]
    }
    if let idx = args.firstIndex(of: "--timeout"), idx + 1 < args.count,
       let t = TimeInterval(args[idx + 1]) {
        timeout = t
    }
    if args.contains("--debug") {
        debug = true
        try? "voice-input started at \(Date())\n".write(
            toFile: debugLogPath, atomically: true, encoding: .utf8)
    }
}

func appendDebugLine(_ msg: String, force: Bool = false) {
    guard debug || force else { return }
    let line = "\(Date()): \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: debugLogPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: debugLogPath, atomically: true, encoding: .utf8)
    }
}

func debugLog(_ msg: String) {
    appendDebugLine(msg)
}

func readVoiceConfig() -> [String: String] {
    let now = Date()
    if now.timeIntervalSince(cachedVoiceConfigReadAt) < voiceConfigCacheTTL {
        return cachedVoiceConfig
    }

    cachedVoiceConfigReadAt = now
    guard let content = try? String(contentsOfFile: voiceConfigPath, encoding: .utf8) else {
        cachedVoiceConfig = [:]
        return cachedVoiceConfig
    }

    var parsed: [String: String] = [:]
    for rawLine in content.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let separator = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[line.index(after: separator)...])
        parsed[key] = value
    }

    cachedVoiceConfig = parsed
    return cachedVoiceConfig
}

func normalizedTarget(_ value: String?) -> String {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude":
        return "claude"
    case "codex":
        return "codex"
    default:
        return "both"
    }
}

struct ProcessSnapshotEntry {
    let pid: pid_t
    let ppid: pid_t
    let command: String
}

func readProcessSnapshot() -> [ProcessSnapshotEntry] {
    let now = Date()
    if now.timeIntervalSince(cachedProcessSnapshotReadAt) < voiceConfigCacheTTL {
        return cachedProcessSnapshot
    }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid=,command="]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        cachedProcessSnapshot = output
            .components(separatedBy: .newlines)
            .compactMap { line -> ProcessSnapshotEntry? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard parts.count == 3,
                      let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1]) else {
                    return nil
                }
                return ProcessSnapshotEntry(pid: pid, ppid: ppid, command: String(parts[2]))
            }
    } catch {
        cachedProcessSnapshot = []
        debugLog("Process snapshot failed: \(error)")
    }

    cachedProcessSnapshotReadAt = now
    return cachedProcessSnapshot
}

func processExecutablePath(for pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
    let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard result > 0 else { return nil }
    return String(cString: buffer)
}

func processCommandLine(for pid: pid_t, snapshot: [ProcessSnapshotEntry]) -> String? {
    snapshot.first(where: { $0.pid == pid })?.command
}

func descendantPIDs(of rootPID: pid_t, snapshot: [ProcessSnapshotEntry]) -> [pid_t] {
    let grouped = Dictionary(grouping: snapshot, by: \.ppid)
    var queue = [rootPID]
    var index = 0
    var descendants: [pid_t] = []

    while index < queue.count {
        let current = queue[index]
        index += 1
        for child in grouped[current] ?? [] {
            descendants.append(child.pid)
            queue.append(child.pid)
        }
    }

    return descendants
}

func targetMatchesProcess(path: String?, commandLine: String?, target: String) -> Bool {
    let targetToken = target.lowercased()
    return [path, commandLine].compactMap { $0?.lowercased() }.contains { $0.contains(targetToken) }
}

func targetMatchReason(path: String?, commandLine: String?, target: String) -> String {
    if let path, path.lowercased().contains(target) {
        return "path"
    }
    if let commandLine, commandLine.lowercased().contains(target) {
        return "argv"
    }
    return "none"
}

func applicationMatchesTarget(_ app: NSRunningApplication, target: String, snapshot: [ProcessSnapshotEntry]) -> (Bool, String) {
    let appPID = app.processIdentifier
    let appPath = processExecutablePath(for: appPID)
    let appCommand = processCommandLine(for: appPID, snapshot: snapshot)
    if targetMatchesProcess(path: appPath, commandLine: appCommand, target: target) {
        return (true, "app-\(targetMatchReason(path: appPath, commandLine: appCommand, target: target))")
    }

    // Known fragile cases: tmux, VS Code integrated terminals, and wrapper
    // scripts can hide the real claude/codex argv, so we also scan descendants
    // and log the exact refusal verdict when the matcher cannot prove scope.
    for descendantPID in descendantPIDs(of: appPID, snapshot: snapshot) {
        let descendantPath = processExecutablePath(for: descendantPID)
        let descendantCommand = processCommandLine(for: descendantPID, snapshot: snapshot)
        if targetMatchesProcess(path: descendantPath, commandLine: descendantCommand, target: target) {
            return (true, "child-\(descendantPID)-\(targetMatchReason(path: descendantPath, commandLine: descendantCommand, target: target))")
        }
    }

    return (false, "no-\(target)-match")
}

func frontmostTargetVerdict(target: String) -> (matches: Bool, detail: String) {
    guard target != "both" else { return (true, "target=both") }
    guard let app = NSWorkspace.shared.frontmostApplication else {
        return (false, "frontmost=none")
    }

    let snapshot = readProcessSnapshot()
    let verdict = applicationMatchesTarget(app, target: target, snapshot: snapshot)
    let appPath = processExecutablePath(for: app.processIdentifier) ?? "<unknown>"
    return (
        verdict.0,
        "frontmost=\(app.localizedName ?? "<unknown>") pid=\(app.processIdentifier) path=\(appPath) verdict=\(verdict.1)"
    )
}

func activateTargetApplication(_ target: String) -> String? {
    let snapshot = readProcessSnapshot()
    let candidates = NSWorkspace.shared.runningApplications.filter { app in
        app.activationPolicy != .prohibited
            && applicationMatchesTarget(app, target: target, snapshot: snapshot).0
    }

    for app in candidates {
        app.activate(options: [.activateIgnoringOtherApps])
        RunLoop.current.run(until: Date().addingTimeInterval(matcherActivationDelay))
        let verdict = frontmostTargetVerdict(target: target)
        if verdict.matches {
            return "activated pid=\(app.processIdentifier) name=\(app.localizedName ?? "<unknown>")"
        }
    }

    return nil
}

func ensureTargetScope(context: String) -> Bool {
    let target = normalizedTarget(readVoiceConfig()["target"])
    guard target != "both" else { return true }

    let frontmost = frontmostTargetVerdict(target: target)
    if frontmost.matches {
        debugLog("TARGET OK [\(context)] \(frontmost.detail)")
        return true
    }

    if let activation = activateTargetApplication(target) {
        let postActivation = frontmostTargetVerdict(target: target)
        appendDebugLine("TARGET ACTIVATE [\(context)] \(activation) \(postActivation.detail)", force: true)
        return postActivation.matches
    }

    appendDebugLine("TARGET BLOCK [\(context)] target=\(target) \(frontmost.detail)", force: true)
    return false
}

// MARK: - WhisperStreamParser

class WhisperStreamParser {
    var confirmedText = ""
    var currentLine = ""
    private var inEscape = false
    private var escapeBuffer = ""

    var fullText: String {
        let confirmed = confirmedText.trimmingCharacters(in: .whitespaces)
        let current = filterHallucinations(
            currentLine.trimmingCharacters(in: .whitespaces))
        if confirmed.isEmpty { return current }
        if current.isEmpty { return confirmed }
        return confirmed + " " + current
    }

    func feed(_ data: Data) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        for char in str {
            if inEscape {
                escapeBuffer.append(char)
                // Looking for [2K sequence
                if char == "K" && escapeBuffer.hasSuffix("[2K") {
                    // Clear line - reset current line
                    currentLine = ""
                    inEscape = false
                    escapeBuffer = ""
                } else if char.isLetter && char != "[" {
                    // End of unrecognized escape sequence
                    inEscape = false
                    escapeBuffer = ""
                }
            } else if char == "\u{1b}" {
                inEscape = true
                escapeBuffer = ""
            } else if char == "\n" || char == "\r\n" {
                let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    let filtered = filterHallucinations(trimmed)
                    if !filtered.isEmpty {
                        if confirmedText.isEmpty {
                            confirmedText = filtered
                        } else {
                            confirmedText += " " + filtered
                        }
                    }
                }
                currentLine = ""
            } else if char == "\r" {
                // carriage return without newline - treat as line reset
                currentLine = ""
            } else {
                currentLine.append(char)
            }
        }
    }

    private func filterHallucinations(_ text: String) -> String {
        var result = text
        // Remove anything in square brackets or parentheses that matches hallucination patterns
        for token in hallucinationTokens {
            result = result.replacingOccurrences(of: token, with: "")
        }
        // Also strip any remaining [anything] or (anything) patterns
        result = result.replacingOccurrences(
            of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "\\([^)]*\\)", with: "", options: .regularExpression)
        // Clean up extra spaces
        result = result.replacingOccurrences(
            of: "  +", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - TextTyper

class TextTyper {
    private let source: CGEventSource?
    var previouslyTyped = ""

    init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    func update(_ newText: String) -> Bool {
        if newText == previouslyTyped { return true }

        if newText.hasPrefix(previouslyTyped) && !previouslyTyped.isEmpty {
            // Append only the new suffix
            let suffix = String(newText.dropFirst(previouslyTyped.count))
            guard typeString(suffix) else { return false }
        } else if previouslyTyped.isEmpty {
            guard typeString(newText) else { return false }
        } else {
            // Diverged - backspace old text and retype
            guard deleteChars(previouslyTyped.count) else { return false }
            usleep(50_000)
            guard typeString(newText) else { return false }
        }
        previouslyTyped = newText
        return true
    }

    func deleteAll() -> Bool {
        if !previouslyTyped.isEmpty {
            guard deleteChars(previouslyTyped.count) else { return false }
            previouslyTyped = ""
        }
        return true
    }

    func deleteChars(_ count: Int) -> Bool {
        for _ in 0..<count {
            guard sendKey(backspaceKeyCode) else { return false }
        }
        return true
    }

    private func typeString(_ str: String) -> Bool {
        // Type using CGEvent unicode string support
        let chars = Array(str.utf16)
        // Send in chunks of up to 20 characters
        var i = 0
        while i < chars.count {
            guard ensureTargetScope(context: "type") else { return false }
            let end = min(i + 20, chars.count)
            var chunk = Array(chars[i..<end])
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cghidEventTap)
            }
            usleep(10_000)
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                event.post(tap: .cghidEventTap)
            }
            usleep(10_000)
            i = end
        }
        return true
    }

    private func sendKey(_ keyCode: CGKeyCode) -> Bool {
        guard ensureTargetScope(context: "key-\(keyCode)") else { return false }
        if let kd = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            kd.post(tap: .cghidEventTap)
        }
        usleep(20_000)
        if let ku = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            ku.post(tap: .cghidEventTap)
        }
        usleep(20_000)
        return true
    }

    func pressEnter() -> Bool {
        sendKey(enterKeyCode)
    }
}

// MARK: - KeywordDetector

class KeywordDetector {
    var onSend: (() -> Void)?
    var onDrillDown: ((String) -> Void)?
    private var pendingWork: DispatchWorkItem?
    private var detected = false
    private var detectedKeyword: String?

    let drillDownKeywords: [(phrase: String, target: String)] = [
        ("read all", "all"),
        ("read rows", "table"),
        ("read table", "table"),
        ("read list", "list"),
        ("read items", "list"),
    ]

    func check(_ text: String) {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Check drill-down keywords first (higher priority than send)
        for kw in drillDownKeywords {
            if lower.hasSuffix(kw.phrase) || lower.hasSuffix(kw.phrase + ".")
                || lower.hasSuffix(kw.phrase + ",") || lower.hasSuffix(kw.phrase + "!") {
                if !detected || detectedKeyword != kw.phrase {
                    pendingWork?.cancel()
                    detected = true
                    detectedKeyword = kw.phrase
                    let target = kw.target
                    debugLog("'\(kw.phrase)' detected, starting \(sendStabilityDelay)s timer")
                    let work = DispatchWorkItem { [weak self] in
                        debugLog("'\(kw.phrase)' stable — triggering drill-down(\(target))")
                        self?.onDrillDown?(target)
                    }
                    pendingWork = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + sendStabilityDelay, execute: work)
                }
                return
            }
        }

        // Fall back to send detection
        let endsSend = lower.hasSuffix("send") || lower.hasSuffix("send.")
            || lower.hasSuffix("send,") || lower.hasSuffix("send!")

        if endsSend {
            if !detected || detectedKeyword != "send" {
                pendingWork?.cancel()
                detected = true
                detectedKeyword = "send"
                debugLog("'send' detected, starting \(sendStabilityDelay)s timer")
                let work = DispatchWorkItem { [weak self] in
                    debugLog("'send' stable — triggering send")
                    self?.onSend?()
                }
                pendingWork = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + sendStabilityDelay, execute: work)
            }
        } else {
            if detected {
                debugLog("'\(detectedKeyword ?? "keyword")' no longer at end, cancelling timer")
                pendingWork?.cancel()
                pendingWork = nil
                detected = false
                detectedKeyword = nil
            }
        }
    }

    func cancel() {
        pendingWork?.cancel()
        pendingWork = nil
        detected = false
        detectedKeyword = nil
    }
}

// MARK: - Main daemon

// Clean up old flags
unlink(stopFlag)
unlink(skipFlag)
unlink(sendingFlag)

let parser = WhisperStreamParser()
let typer = TextTyper()
let detector = KeywordDetector()
var whisperProcess: Process?
var exiting = false

func shutdown(deletingText: Bool = false) {
    guard !exiting else { return }
    try? FileManager.default.removeItem(atPath: sendingFlag)
    exiting = true
    detector.cancel()

    if let proc = whisperProcess, proc.isRunning {
        debugLog("Terminating whisper-stream (pid \(proc.processIdentifier))")
        proc.terminate()
        proc.waitUntilExit()
    }

    if deletingText {
        debugLog("Skip: deleting all typed text (\(typer.previouslyTyped.count) chars)")
        _ = typer.deleteAll()
    }

    usleep(200_000)
    exit(0)
}

func triggerSend() {
    guard !exiting else { return }
    exiting = true
    debugLog("TRIGGER SEND")

    // Kill whisper-stream
    if let proc = whisperProcess, proc.isRunning {
        proc.terminate()
        proc.waitUntilExit()
    }
    usleep(200_000)

    // Calculate how many chars to delete for "send" + punctuation + space
    let text = typer.previouslyTyped
    let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    var deleteCount = 4  // "send"
    if lower.hasSuffix("send.") || lower.hasSuffix("send,") || lower.hasSuffix("send!") {
        deleteCount = 5
    }
    // Add 1 for the space before "send"
    if text.count > deleteCount {
        let checkIdx = text.index(text.endIndex, offsetBy: -deleteCount)
        if checkIdx > text.startIndex {
            let before = text[text.index(before: checkIdx)]
            if before == " " { deleteCount += 1 }
        }
    }

    debugLog("Deleting \(deleteCount) chars, then Enter")
    guard typer.deleteChars(deleteCount) else {
        appendDebugLine("SEND ABORTED target gate blocked delete path", force: true)
        usleep(200_000)
        exit(0)
    }
    typer.previouslyTyped = String(
        typer.previouslyTyped.dropLast(deleteCount))
    usleep(100_000)

    // Flag that WE are pressing Enter (so skip-listener ignores it)
    FileManager.default.createFile(atPath: sendingFlag, contents: nil)
    guard typer.pressEnter() else {
        try? FileManager.default.removeItem(atPath: sendingFlag)
        appendDebugLine("SEND ABORTED target gate blocked Enter", force: true)
        usleep(200_000)
        exit(0)
    }
    usleep(100_000)
    try? FileManager.default.removeItem(atPath: sendingFlag)

    debugLog("Send complete, exiting")
    usleep(200_000)
    exit(0)
}

func triggerDrillDown(_ target: String) {
    guard !exiting else { return }
    debugLog("TRIGGER DRILL-DOWN: \(target)")

    // Kill whisper-stream
    if let proc = whisperProcess, proc.isRunning {
        proc.terminate()
        proc.waitUntilExit()
    }
    usleep(200_000)

    // Delete all typed text (keyword consumed, not sent to Claude)
    guard typer.deleteAll() else {
        appendDebugLine("DRILL-DOWN ABORTED target gate blocked cleanup", force: true)
        usleep(200_000)
        exit(0)
    }
    usleep(100_000)

    // Write drill-down flag for skip-listener to pick up
    let flagPath = "/tmp/claude-tts-drill-down"
    try? target.write(toFile: flagPath, atomically: true, encoding: .utf8)

    debugLog("Drill-down flag written, exiting")
    usleep(200_000)
    exit(0)
}

detector.onSend = triggerSend
detector.onDrillDown = triggerDrillDown

// Launch whisper-stream
let process = Process()
process.executableURL = URL(fileURLWithPath: whisperStreamPath)
process.arguments = [
    "-m", modelPath,
    "--step", "3000",
    "--length", "8000",
    "--vad-thold", "0.8",
]
process.standardError = FileHandle.nullDevice

let pipe = Pipe()
process.standardOutput = pipe
whisperProcess = process

debugLog("Launching: \(whisperStreamPath) -m \(modelPath)")

do {
    try process.run()
    debugLog("whisper-stream launched (pid \(process.processIdentifier))")
} catch {
    debugLog("FATAL: Failed to launch whisper-stream: \(error)")
    fputs("Error: Failed to launch whisper-stream: \(error)\n", stderr)
    exit(1)
}

// Read whisper-stream stdout asynchronously
let readQueue = DispatchQueue(label: "whisper-reader")
pipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    if data.isEmpty {
        handle.readabilityHandler = nil
        debugLog("whisper-stream stdout closed")
        DispatchQueue.main.async { shutdown() }
        return
    }

    readQueue.async {
        parser.feed(data)
        let text = parser.fullText

        DispatchQueue.main.async {
            if !exiting {
                if !typer.update(text) {
                    appendDebugLine("VOICE INPUT ABORT target gate blocked keystroke send", force: true)
                    shutdown()
                    return
                }
                detector.check(text)
                debugLog("Text: '\(text.suffix(50))'")
            }
        }
    }
}

// Poll for flags and timeout
let startTime = Date()
let pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
    guard !exiting else { return }

    // Check timeout
    if Date().timeIntervalSince(startTime) >= timeout {
        debugLog("Timeout (\(timeout)s)")
        shutdown()
        return
    }

    // Check stop flag (leave text)
    if FileManager.default.fileExists(atPath: stopFlag) {
        try? FileManager.default.removeItem(atPath: stopFlag)
        debugLog("Stop flag detected")
        shutdown()
        return
    }

    // Check skip flag (delete all text)
    if FileManager.default.fileExists(atPath: skipFlag) {
        try? FileManager.default.removeItem(atPath: skipFlag)
        debugLog("Skip flag detected")
        shutdown(deletingText: true)
        return
    }

    // Check if whisper-stream died
    if let proc = whisperProcess, !proc.isRunning {
        debugLog("whisper-stream exited (code \(proc.terminationStatus))")
        shutdown()
        return
    }
}

RunLoop.current.add(pollTimer, forMode: .common)
RunLoop.current.run()
