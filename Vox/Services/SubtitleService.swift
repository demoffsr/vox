import Foundation

@MainActor
final class SubtitleService {
    private let audioCaptureManager = AudioCaptureManager()
    private let whisperTranscriber = WhisperTranscriber()
    private var translator: SubtitleTranslator?
    private let ipcFile = FileManager.default.temporaryDirectory.appendingPathComponent("vox-subtitles.json")

    private(set) var isRunning = false

    func start() async {
        guard !isRunning else { return }

        // 1. Load API key
        let apiKey: String
        do {
            guard let key = try KeychainHelper().load(), !key.isEmpty else {
                print("[SubtitleService] No API key found in keychain")
                return
            }
            apiKey = key
        } catch {
            print("[SubtitleService] Failed to load API key: \(error)")
            return
        }

        // 2. Init translator
        translator = SubtitleTranslator(apiKey: apiKey)

        // 3. Load Whisper model
        do {
            try whisperTranscriber.loadModel()
        } catch {
            print("[SubtitleService] Failed to load Whisper model: \(error)")
            return
        }

        // 4. Set up audio chunk callback — uses completion handler, not async
        audioCaptureManager.onAudioChunk = { [weak self] samples in
            self?.processAudioChunk(samples)
        }

        // 5. Start audio capture
        do {
            try await audioCaptureManager.startCapture()
        } catch {
            print("[SubtitleService] Failed to start audio capture: \(error)")
            return
        }

        isRunning = true
        print("[SubtitleService] Started — listening for audio")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        await audioCaptureManager.stopCapture()
        print("[SubtitleService] Stopped")
    }

    // Called from audio queue — no async/await
    private nonisolated func processAudioChunk(_ samples: [Float]) {
        whisperTranscriber.transcribe(audioFrames: samples) { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            print("[SubtitleService] Transcribed: \(text)")

            // Translate on a background task
            guard let translator = self.translator else { return }
            Task.detached {
                do {
                    let translated = try await translator.translate(text)
                    print("[SubtitleService] Translated: \(translated)")
                    self.writeSubtitle(translated)
                } catch {
                    print("[SubtitleService] Translation error: \(error)")
                }
            }
        }
    }

    private nonisolated func writeSubtitle(_ text: String) {
        let dict: [String: Any] = [
            "text": text,
            "timestamp": Date().timeIntervalSince1970,
            "status": "listening"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: ipcFile, options: .atomic)
    }
}
