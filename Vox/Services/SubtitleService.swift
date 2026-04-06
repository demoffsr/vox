import Foundation

@MainActor
final class SubtitleService {
    private let audioCaptureManager = AudioCaptureManager()
    private let whisperTranscriber = WhisperTranscriber()
    private let audioBuffer = AudioBuffer()
    private let ipcFile: URL = {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.Vox.Vox")!
        return container.appendingPathComponent("vox-subtitles.json")
    }()

    private(set) var isRunning = false

    func start() async {
        guard !isRunning else { return }

        // Load Whisper model
        do {
            try whisperTranscriber.loadModel()
        } catch {
            print("[SubtitleService] Failed to load Whisper model: \(error)")
            return
        }

        // Set up audio chunk callback
        audioCaptureManager.onAudioChunk = { [weak self] samples in
            self?.processAudioChunk(samples)
        }

        // Start audio capture
        do {
            try await audioCaptureManager.startCapture()
        } catch {
            print("[SubtitleService] Failed to start audio capture: \(error)")
            return
        }

        isRunning = true
        writeSubtitleState(text: "", status: "listening")
        print("[SubtitleService] Started — listening for audio")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        await audioCaptureManager.stopCapture()
        whisperTranscriber.cancelIfBusy()
        audioBuffer.reset()
        writeSubtitleState(text: "", status: "stopped")
        print("[SubtitleService] Stopped")
    }

    // Called from audio queue — accumulates audio instead of dropping
    private nonisolated func processAudioChunk(_ samples: [Float]) {
        audioBuffer.append(samples)
        drainPendingAudio()
    }

    /// Transcribes accumulated audio when whisper is free.
    private nonisolated func drainPendingAudio() {
        guard !whisperTranscriber.isBusy else { return }
        guard let audio = audioBuffer.tryDrain() else { return }

        whisperTranscriber.transcribe(audioFrames: audio) { [weak self] text in
            guard let self else { return }

            self.audioBuffer.finishDrain()

            if let text, !text.isEmpty {
                print("[SubtitleService] Transcribed: \(text)")
                self.writeSubtitleState(text: text, status: "listening")
            }

            // Process any audio that accumulated while transcribing
            self.drainPendingAudio()
        }
    }

    private nonisolated func writeSubtitleState(text: String, status: String) {
        let dict: [String: Any] = [
            "text": text,
            "timestamp": Date().timeIntervalSince1970,
            "status": status
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: ipcFile, options: .atomic)
    }
}

/// Thread-safe audio buffer for accumulating chunks between transcription runs.
private final class AudioBuffer: @unchecked Sendable {
    nonisolated(unsafe) private var samples: [Float] = []
    nonisolated(unsafe) private var _isDraining = false
    private let lock = NSLock()
    private let maxSamples = 160_000  // 10 seconds at 16 kHz

    nonisolated init() {}

    nonisolated func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        if samples.count > maxSamples {
            let excess = samples.count - maxSamples
            samples.removeFirst(excess)
        }
        lock.unlock()
    }

    nonisolated func tryDrain() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard !_isDraining, !samples.isEmpty else { return nil }
        _isDraining = true
        let audio = samples
        samples.removeAll()
        return audio
    }

    nonisolated func finishDrain() {
        lock.lock()
        _isDraining = false
        lock.unlock()
    }

    nonisolated func reset() {
        lock.lock()
        samples.removeAll()
        _isDraining = false
        lock.unlock()
    }
}
