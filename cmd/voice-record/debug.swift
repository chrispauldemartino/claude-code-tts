import AVFoundation
import Foundation

// Debug version: just monitors mic levels for 5 seconds to diagnose

let semaphore = DispatchSemaphore(value: 0)
var permissionGranted = false

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    permissionGranted = true
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        permissionGranted = granted
        semaphore.signal()
    }
    semaphore.wait()
default:
    permissionGranted = false
}

guard permissionGranted else {
    fputs("Mic permission denied\n", stderr)
    exit(1)
}

// List available audio devices
let discoverySession = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.microphone, .builtInMicrophone, .external],
    mediaType: .audio,
    position: .unspecified
)
fputs("Available audio devices:\n", stderr)
for device in discoverySession.devices {
    fputs("  - \(device.localizedName) [\(device.uniqueID)]\n", stderr)
}

if let defaultDevice = AVCaptureDevice.default(for: .audio) {
    fputs("Default device: \(defaultDevice.localizedName)\n", stderr)
}

let url = URL(fileURLWithPath: "/tmp/voice-debug.wav")
let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false
]

guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
    fputs("Failed to create recorder\n", stderr)
    exit(1)
}

recorder.isMeteringEnabled = true
recorder.record()

fputs("Recording for 5 seconds — SPEAK NOW...\n", stderr)
for i in 0..<50 {
    Thread.sleep(forTimeInterval: 0.1)
    recorder.updateMeters()
    let avg = recorder.averagePower(forChannel: 0)
    let peak = recorder.peakPower(forChannel: 0)
    if i % 5 == 0 {
        fputs(String(format: "  %.1fs  avg: %.1f dB  peak: %.1f dB\n", Double(i) * 0.1, avg, peak), stderr)
    }
}

recorder.stop()
fputs("Done.\n", stderr)
