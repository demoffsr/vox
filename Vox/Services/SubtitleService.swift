import Foundation

@MainActor
final class SubtitleService {
    private let audioCaptureManager = AudioCaptureManager()
    private let whisperTranscriber = WhisperTranscriber()
    private var translator: SubtitleTranslator?
    private let ipcFile = FileManager.default.temporaryDirectory.appendingPathComponent("vox-subtitles.json")

    private(set) var isRunning = false
    private var pipelineTask: Task<Void, Never>?

    // Thread-safe queue for pending audio chunks waiting for transcription
    private var pendingAudio: [[Float]] = []
    private let audioLock = NSLock()

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

        // 4. Set up audio chunk callback: queue audio for processing
        audioCaptureManager.onAudioChunk = { [weak self] samples in
            guard let self else { return }
            self.audioLock.lock()
            self.pendingAudio.append(samples)
            self.audioLock.unlock()
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
        publishStatus("listening")

        // 7. Start processing pipeline on a detached (non-MainActor) task
        let whisper = whisperTranscriber
        let trans = translator!
        let lock = audioLock
        let ipc = ipcFile

        pipelineTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                // Grab next audio chunk
                lock.lock()
                let audio = self?.pendingAudio.isEmpty == false ? self?.pendingAudio.removeFirst() : nil
                lock.unlock()

                guard let audio else {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    continue
                }

                // Transcribe (runs off main thread)
                do {
                    let text = try await whisper.transcribe(audioFrames: audio)
                    guard !text.isEmpty else { continue }
                    print("[SubtitleService] Transcribed: \(text)")

                    // Translate
                    let translated = try await trans.translate(text)
                    print("[SubtitleService] Translated: \(translated)")

                    // Write to IPC file
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
        pipelineTask?.cancel()
        await audioCaptureManager.stopCapture()
        publishStatus("stopped")
    }

    // MARK: - Publishing

    private func publishStatus(_ status: String) {
        let dict: [String: Any] = ["text": "", "timestamp": 0, "status": status]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: ipcFile, options: .atomic)
    }
}
