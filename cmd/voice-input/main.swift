import Foundation
import CoreGraphics

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

func debugLog(_ msg: String) {
    guard debug else { return }
    let line = "\(Date()): \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: debugLogPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    }
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

    func update(_ newText: String) {
        if newText == previouslyTyped { return }

        if newText.hasPrefix(previouslyTyped) && !previouslyTyped.isEmpty {
            // Append only the new suffix
            let suffix = String(newText.dropFirst(previouslyTyped.count))
            typeString(suffix)
        } else if previouslyTyped.isEmpty {
            typeString(newText)
        } else {
            // Diverged - backspace old text and retype
            deleteChars(previouslyTyped.count)
            usleep(50_000)
            typeString(newText)
        }
        previouslyTyped = newText
    }

    func deleteAll() {
        if !previouslyTyped.isEmpty {
            deleteChars(previouslyTyped.count)
            previouslyTyped = ""
        }
    }

    func deleteChars(_ count: Int) {
        for _ in 0..<count {
            sendKey(backspaceKeyCode)
        }
    }

    private func typeString(_ str: String) {
        // Type using CGEvent unicode string support
        let chars = Array(str.utf16)
        // Send in chunks of up to 20 characters
        var i = 0
        while i < chars.count {
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
    }

    private func sendKey(_ keyCode: CGKeyCode) {
        if let kd = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            kd.post(tap: .cghidEventTap)
        }
        usleep(20_000)
        if let ku = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            ku.post(tap: .cghidEventTap)
        }
        usleep(20_000)
    }

    func pressEnter() {
        sendKey(enterKeyCode)
    }
}

// MARK: - SendDetector

class SendDetector {
    var onSend: (() -> Void)?
    private var pendingWork: DispatchWorkItem?
    private var detected = false

    func check(_ text: String) {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let endsSend = lower.hasSuffix("send") || lower.hasSuffix("send.")
            || lower.hasSuffix("send,") || lower.hasSuffix("send!")

        if endsSend {
            if !detected {
                detected = true
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
                debugLog("'send' no longer at end, cancelling timer")
                pendingWork?.cancel()
                pendingWork = nil
                detected = false
            }
        }
    }

    func cancel() {
        pendingWork?.cancel()
        pendingWork = nil
        detected = false
    }
}

// MARK: - Main daemon

// Clean up old flags
unlink(stopFlag)
unlink(skipFlag)
unlink(sendingFlag)

let parser = WhisperStreamParser()
let typer = TextTyper()
let detector = SendDetector()
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
        typer.deleteAll()
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
    typer.deleteChars(deleteCount)
    typer.previouslyTyped = String(
        typer.previouslyTyped.dropLast(deleteCount))
    usleep(100_000)

    // Flag that WE are pressing Enter (so skip-listener ignores it)
    FileManager.default.createFile(atPath: sendingFlag, contents: nil)
    typer.pressEnter()
    usleep(100_000)
    try? FileManager.default.removeItem(atPath: sendingFlag)

    debugLog("Send complete, exiting")
    usleep(200_000)
    exit(0)
}

detector.onSend = triggerSend

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
                typer.update(text)
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
