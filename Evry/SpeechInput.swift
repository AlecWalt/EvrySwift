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

    func toggle() {
        if isListening { stop(); return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:    startRecording()
        case .notDetermined: requestAndStart()
        default:             permissionDenied = true
        }
    }

    func stop() {
        if let engine, engine.isRunning {
            engine.stop()
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
        let engine = self.engine ?? AVAudioEngine()
        self.engine = engine
        // Activating the audio session + starting the engine blocks for tens of
        // milliseconds; doing it on the main thread hitches the start-listening
        // animation. Run it off-main and flip `isListening` back on the main queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch { return }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true

            let node = engine.inputNode
            node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [weak self] buf, _ in
                req.append(buf)
                self?.updateLevel(buf)
            }
            do { try engine.start() } catch { self.stop(); return }

            let task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                guard let self else { return }
                if let r = result {
                    DispatchQueue.main.async { self.transcript = r.bestTranscription.formattedString }
                }
                if err != nil || result?.isFinal == true {
                    DispatchQueue.main.async { self.stop() }
                }
            }

            DispatchQueue.main.async {
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
