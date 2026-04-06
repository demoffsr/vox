import Foundation

@MainActor
final class SubtitleService {
    private let audioCaptureManager = AudioCaptureManager()
    private let whisperTranscriber = WhisperTranscriber()
    private var translator: SubtitleTranslator?
    private let ipcFile = URL(fileURLWithPath: "/tmp/vox-subtitles.json")

    private(set) var isRunning = false
    private var pipelineTask: Task<Void, Never>?

    // Thread-safe queue for pending transcription chunks
    private var pendingChunks: [String] = []
    private let chunkLock = NSLock()

    func start() async {
        guard !isRunning else { return }

        // 1. Load API key from keychain
        let apiKey: String
        do {
            guard let key = try KeychainHelper().load(), !key.isEmpty else {
                print("[SubtitleService] No API key found in keychain")
                publishStatus("error")
                return
            }
            apiKey = key
        } catch {
            print("[SubtitleService] Failed to load API key: \(error)")
            publishStatus("error")
            return
        }

        // 2. Init translator
        translator = SubtitleTranslator(apiKey: apiKey)

        // 3. Load Whisper model
        do {
            try whisperTranscriber.loadModel()
        } catch {
            print("[SubtitleService] Failed to load Whisper model: \(error)")
            publishStatus("error")
            return
        }

        // 4. Set up audio chunk callback: transcribe and enqueue
        audioCaptureManager.onAudioChunk = { [weak self] samples in
            guard let self else { return }
            Task {
                do {
                    let text = try await self.whisperTranscriber.transcribe(audioFrames: samples)
                    guard !text.isEmpty else { return }
                    self.chunkLock.lock()
                    self.pendingChunks.append(text)
                    self.chunkLock.unlock()
                } catch {
                    print("[SubtitleService] Transcription error: \(error)")
                }
            }
        }

        // 5. Start audio capture
        do {
            try await audioCaptureManager.startCapture()
        } catch {
            print("[SubtitleService] Failed to start audio capture: \(error)")
            publishStatus("error")
            return
        }

        // 6. Mark as running
        isRunning = true

        // 7. Publish listening status
        publishStatus("listening")

        // 8. Start translation pipeline loop
        pipelineTask = Task { [weak self] in
            await self?.translationLoop()
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        pipelineTask?.cancel()
        await audioCaptureManager.stopCapture()
        publishStatus("stopped")
        publishSubtitle("")
    }

    // MARK: - Translation Pipeline

    private func translationLoop() async {
        while !Task.isCancelled {
            // Grab next pending chunk
            chunkLock.lock()
            let chunk = pendingChunks.isEmpty ? nil : pendingChunks.removeFirst()
            chunkLock.unlock()

            if let chunk {
                do {
                    guard let translator else { continue }
                    let translated = try await translator.translate(chunk)
                    publishSubtitle(translated)
                } catch {
                    print("[SubtitleService] Translation error: \(error)")
                }
            } else {
                // No chunk available — sleep briefly before checking again
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    // MARK: - Publishing

    private func publishSubtitle(_ text: String) {
        writeIPC(["text": text, "timestamp": Date().timeIntervalSince1970, "status": "listening"])
    }

    private func publishStatus(_ status: String) {
        writeIPC(["text": "", "timestamp": 0, "status": status])
    }

    private func writeIPC(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: ipcFile, options: .atomic)
    }
}
