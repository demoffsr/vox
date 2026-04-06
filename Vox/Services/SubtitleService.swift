import Foundation

@MainActor
final class SubtitleService {
    private let audioCaptureManager = AudioCaptureManager()
    private let whisperTranscriber = WhisperTranscriber()
    private var translator: SubtitleTranslator?
    private let ipcFile = FileManager.default.temporaryDirectory.appendingPathComponent("vox-subtitles.json")

    private(set) var isRunning = false
    private var pipelineTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<[Float]>.Continuation?

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

        // 4. Create async stream for audio chunks
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.audioContinuation = continuation

        // 5. Set up audio chunk callback
        audioCaptureManager.onAudioChunk = { [weak self] samples in
            self?.audioContinuation?.yield(samples)
        }

        // 6. Start audio capture
        do {
            try await audioCaptureManager.startCapture()
        } catch {
            print("[SubtitleService] Failed to start audio capture: \(error)")
            publishStatus("error")
            return
        }

        // 7. Mark as running
        isRunning = true
        publishStatus("listening")

        // 8. Start processing pipeline on detached task
        let whisper = whisperTranscriber
        let trans = translator!
        let ipc = ipcFile

        pipelineTask = Task.detached {
            for await audio in stream {
                do {
                    let text = try await whisper.transcribe(audioFrames: audio)
                    guard !text.isEmpty else { continue }
                    print("[SubtitleService] Transcribed: \(text)")

                    let translated = try await trans.translate(text)
                    print("[SubtitleService] Translated: \(translated)")

                    let dict: [String: Any] = [
                        "text": translated,
                        "timestamp": Date().timeIntervalSince1970,
                        "status": "listening"
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: dict) {
                        try? data.write(to: ipc, options: .atomic)
                    }
                } catch {
                    print("[SubtitleService] Pipeline error: \(error)")
                }
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        audioContinuation?.finish()
        audioContinuation = nil
        pipelineTask?.cancel()
        await audioCaptureManager.stopCapture()
        publishStatus("stopped")
    }

    private func publishStatus(_ status: String) {
        let dict: [String: Any] = ["text": "", "timestamp": 0, "status": status]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: ipcFile, options: .atomic)
    }
}
