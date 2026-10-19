// SpeechInput.swift — Shared live speech transcription model.
import Foundation
import Speech
import AVFoundation

@Observable
final class LiveSpeechInput {
    var transcript = ""
    var isListening = false
    var permissionDenied = false
    /// Smoothed 0…1 mic amplitude — drives the calm "breathing" listening orb so
    /// it responds to the voice instead of showing a generic spinner.
    var level: Double = 0

    // Made on first use, not at init: views hold this as @State, whose initial
    // value is re-created every time the view is re-initialised.
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    /// A start is in flight on the background queue (isListening isn't set yet).
    @ObservationIgnored private var starting = false
    /// Bumped by every stop, so a start or a recognition callback from an older
    /// session can tell it's stale and must not touch the current one.
    @ObservationIgnored private var generation = 0
    /// Serial, so one start's tap/engine setup finishes before the next begins.
    @ObservationIgnored private let audioQueue = DispatchQueue(label: "evry.speech", qos: .userInitiated)

    func toggle() {
        if isListening || starting { stop(); return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:    startRecording()
        case .notDetermined: requestAndStart()
        default:             permissionDenied = true
        }
    }

    func stop() {
        generation += 1
        starting = false
        if let engine {
            if engine.isRunning { engine.stop() }
            // Always remove the tap — one left behind (e.g. after the engine
            // failed to start) makes the next installTap crash.
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil; isListening = false
        DispatchQueue.main.async { self.level = 0 }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                if status == .authorized { self?.startRecording() }
                else { self?.permissionDenied = true }
            }
        }
    }

    private func startRecording() {
        if recognizer == nil { recognizer = SFSpeechRecognizer() }
        guard let recognizer, recognizer.isAvailable else { return }
        guard !starting, !isListening else { return }
        let engine = self.engine ?? AVAudioEngine()
        self.engine = engine
        starting = true
        let gen = generation
        // Activating the audio session + starting the engine blocks for tens of
        // milliseconds; doing it on the main thread hitches the start-listening
        // animation. Run it off-main and flip `isListening` back on the main queue.
        audioQueue.async { [weak self] in
            guard let self else { return }
            let node = engine.inputNode
            // Clean slate: an earlier, cancelled start may have left its tap.
            if engine.isRunning { engine.stop() }
            node.removeTap(onBus: 0)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                DispatchQueue.main.async { if self.generation == gen { self.starting = false } }
                return
            }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true

            node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [weak self] buf, _ in
                req.append(buf)
                self?.updateLevel(buf)
            }
            do { try engine.start() } catch {
                node.removeTap(onBus: 0)
                // stop() touches observed state, so it runs on the main queue.
                DispatchQueue.main.async { if self.generation == gen { self.stop() } }
                return
            }

            let task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                guard let self else { return }
                if let r = result {
                    DispatchQueue.main.async {
                        if self.generation == gen { self.transcript = r.bestTranscription.formattedString }
                    }
                }
                if err != nil || result?.isFinal == true {
                    DispatchQueue.main.async { if self.generation == gen { self.stop() } }
                }
            }

            DispatchQueue.main.async {
                // Stopped while starting: undo this start instead of going live.
                guard self.generation == gen else {
                    // Leave the engine to a newer start if one is on its way
                    // (it resets the engine itself); otherwise shut it down.
                    if !self.starting && !self.isListening {
                        engine.stop()
                        node.removeTap(onBus: 0)
                    }
                    req.endAudio()
                    task.cancel()
                    return
                }
                self.starting = false
                self.request = req
                self.task = task
                self.isListening = true
            }
        }
    }

    /// RMS amplitude of a mic buffer, mapped and smoothed to 0…1. Rises quickly
    /// and falls gently so the listening orb breathes calmly rather than jittering.
    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in 0..<frames { let s = channel[i]; sum += s * s }
        let rms = sqrt(sum / Float(frames))
        let scaled = min(1, Double(rms) * 12)   // typical speech RMS ~0.02–0.08
        DispatchQueue.main.async {
            let prev = self.level
            let factor = scaled > prev ? 0.6 : 0.2   // attack fast, release slow
            self.level = prev + (scaled - prev) * factor
        }
    }
}
