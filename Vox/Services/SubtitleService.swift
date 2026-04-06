import Foundation
import AVFoundation

@MainActor
final class SubtitleService {
    private let audioCapture = SystemAudioCapture()
    private let transcriber = LiveTranscriber()
    private let subtitlePanel = SubtitlePanel()

    private let ipcFile: URL = {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)!
        return container.appendingPathComponent("vox-subtitles.json")
    }()

    private(set) var isRunning = false
    private var captureTask: Task<Void, Never>?
    private var lastWriteTime: TimeInterval = 0
    private var lastWrittenText: String = ""

    /// The current subtitle language locale identifier (e.g. "en-US", "ru-RU").
    var subtitleLocale: Locale = Locale(identifier: "en-US")

    func start() async {
        guard !isRunning else { return }

        // Wire up transcription → display + IPC
        // Volatile results = word-by-word, final = confirmed sentence
        transcriber.onSubtitle = { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                if isFinal {
                    self.subtitlePanel.showFinal(text)
                } else {
                    self.subtitlePanel.showVolatile(text)
                }
                self.throttledWriteIPC(text: text)
            }
        }

        // Start transcription engine first — determines required audio format
        await transcriber.start(locale: subtitleLocale)

        // Start audio capture in the format SpeechAnalyzer wants — no conversion needed
        let preferredFormat = transcriber.preferredAudioFormat
        print("[SubtitleService] SpeechAnalyzer wants format: \(preferredFormat?.description ?? "nil")")

        do {
            try await audioCapture.startCapture(audioFormat: preferredFormat)
        } catch {
            print("[SubtitleService] Failed to start audio capture: \(error)")
            transcriber.stop()
            return
        }

        // Forward audio buffers from capture → transcriber
        captureTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in await self.audioCapture.audioBuffers {
                guard !Task.isCancelled else { break }
                self.transcriber.appendAudioBuffer(buffer)
            }
        }

        isRunning = true
        writeSubtitleState(text: "", status: "listening")
        print("[SubtitleService] Started — system-wide audio → SpeechAnalyzer")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        captureTask?.cancel()
        captureTask = nil
        transcriber.stop()
        await audioCapture.stopCapture()

        subtitlePanel.fadeOut()
        writeSubtitleState(text: "", status: "stopped")
        print("[SubtitleService] Stopped")
    }

    // MARK: - IPC for Safari Extension

    private func throttledWriteIPC(text: String) {
        guard text != lastWrittenText else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastWriteTime >= 0.1 else { return } // max 10 writes/sec
        lastWriteTime = now
        lastWrittenText = text
        writeSubtitleState(text: text, status: "listening")
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
