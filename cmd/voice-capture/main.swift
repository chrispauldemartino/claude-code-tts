import Foundation
import Speech
import AVFoundation

// Voice capture using on-device SFSpeechRecognizer
// Records from mic, transcribes in real-time, exits after silence detected
// Prints final transcription to stdout

class VoiceCapture {
    let audioEngine = AVAudioEngine()
    let recognizer: SFSpeechRecognizer
    var task: SFSpeechRecognitionTask?
    let request = SFSpeechAudioBufferRecognitionRequest()
    var silenceWork: DispatchWorkItem?
    var text = ""
    var started = false
    let silenceTimeout: TimeInterval
    let maxDuration: TimeInterval
    let initialWait: TimeInterval

    init(silence: TimeInterval = 2.0, max: TimeInterval = 30.0, initial: TimeInterval = 8.0) {
        self.silenceTimeout = silence
        self.maxDuration = max
        self.initialWait = initial
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    }

    func start() {
        request.shouldReportPartialResults = true

        let node = audioEngine.inputNode
        let fmt = node.outputFormat(forBus: 0)

        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request.append(buf)
        }

        audioEngine.prepare()
        do { try audioEngine.start() }
        catch {
            fputs("mic error: \(error)\n", stderr)
            exit(1)
        }

        // Hard max duration
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration) { [weak self] in
            self?.finish()
        }

        // If no speech detected at all within initialWait, exit empty
        DispatchQueue.main.asyncAfter(deadline: .now() + initialWait) { [weak self] in
            guard let s = self else { return }
            if !s.started { s.finish() }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let s = self else { return }

            if let r = result {
                s.text = r.bestTranscription.formattedString
                s.started = true

                // Reset silence timer on each partial result
                s.silenceWork?.cancel()
                let work = DispatchWorkItem { s.finish() }
                s.silenceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + s.silenceTimeout, execute: work)

                if r.isFinal { s.finish() }
            }
            if error != nil && !s.started { s.finish() }
        }
    }

    func finish() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task?.cancel()
        if !text.isEmpty { print(text) }
        exit(0)
    }
}

// Authorize speech recognition
let sem = DispatchSemaphore(value: 0)
SFSpeechRecognizer.requestAuthorization { status in
    if status != .authorized {
        fputs("Speech recognition not authorized. Enable in System Settings > Privacy & Security > Speech Recognition.\n", stderr)
        exit(1)
    }
    sem.signal()
}
sem.wait()

let vc = VoiceCapture()
vc.start()
RunLoop.main.run()
