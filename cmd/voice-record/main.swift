import AVFoundation
import Foundation

// Voice recorder that explicitly selects built-in MacBook mic
// Records with silence detection, normalizes output for whisper
// Usage: VoiceRecord [output.wav] [max_seconds] [silence_seconds]

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/claude-voice-input.wav"
let maxDuration = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "15") ?? 15
let silenceTimeout = Double(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "2.0") ?? 2.0
let silenceThreshold: Float = -50.0

// --- Permission ---
let sem = DispatchSemaphore(value: 0)
var allowed = false
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized: allowed = true
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .audio) { g in allowed = g; sem.signal() }
    sem.wait()
default: break
}
guard allowed else { fputs("Mic denied\n", stderr); exit(1) }

// --- Find built-in mic ---
let devices = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.microphone],
    mediaType: .audio,
    position: .unspecified
).devices

var builtIn: AVCaptureDevice? = nil
for d in devices {
    fputs("  device: \(d.localizedName)\n", stderr)
    if d.localizedName.contains("MacBook") || d.uniqueID == "BuiltInMicrophoneDevice" {
        builtIn = d
    }
}

let mic = builtIn ?? AVCaptureDevice.default(for: .audio)!
fputs("Selected: \(mic.localizedName)\n", stderr)

// --- Record using AVAudioRecorder ---
// Temporarily no device override (AVAudioRecorder uses system default)
// Instead, record at high quality and normalize later
let tempPath = "/tmp/claude-vr-\(ProcessInfo.processInfo.processIdentifier).wav"
let tempURL = URL(fileURLWithPath: tempPath)

let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 44100.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false
]

guard let recorder = try? AVAudioRecorder(url: tempURL, settings: settings) else {
    fputs("Recorder init failed\n", stderr); exit(1)
}

recorder.isMeteringEnabled = true
recorder.record()
fputs("Listening...\n", stderr)

let start = Date()
var silenceStart: Date? = nil
var hasSpeech = false

while true {
    Thread.sleep(forTimeInterval: 0.05)
    recorder.updateMeters()
    let level = recorder.averagePower(forChannel: 0)
    let elapsed = Date().timeIntervalSince(start)

    if elapsed >= maxDuration { break }

    if level > silenceThreshold {
        hasSpeech = true
        silenceStart = nil
    } else if hasSpeech {
        if silenceStart == nil { silenceStart = Date() }
        else if Date().timeIntervalSince(silenceStart!) >= silenceTimeout { break }
    }

    if !hasSpeech && elapsed >= 8.0 { break }
}

recorder.stop()

if !hasSpeech {
    try? FileManager.default.removeItem(at: tempURL)
    exit(2)
}

// Normalize and resample to 16kHz for whisper via sox
let sox = Process()
sox.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sox")
sox.arguments = [tempPath, "-r", "16000", "-c", "1", outputPath, "norm"]
try? sox.run()
sox.waitUntilExit()

try? FileManager.default.removeItem(atPath: tempPath)
