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

    // Translation state — intentionally minimal
    private var translator: SubtitleTranslator?
    private var pendingTranslation: Task<Void, Never>?
    private var translationTimer: Task<Void, Never>?
    private var lastTranslationTime: TimeInterval = 0
    private var lastTranslatedInput: String = ""
    private var rateLimitUntil: TimeInterval = 0

    /// The current subtitle language locale identifier (e.g. "en-US", "ru-RU").
    var subtitleLocale: Locale = Locale(identifier: "en-US")

    func start() async {
        guard !isRunning else { return }

        transcriber.onSubtitle = { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                if isFinal {
                    self.subtitlePanel.showFinal(text)
                } else {
                    self.subtitlePanel.showVolatile(text)
                }
                self.throttledWriteIPC(text: self.subtitlePanel.displayText)
                self.onNewWords()
            }
        }

        await transcriber.start(locale: subtitleLocale)

        let preferredFormat = transcriber.preferredAudioFormat
        print("[SubtitleService] SpeechAnalyzer wants format: \(preferredFormat?.description ?? "nil")")

        do {
            try await audioCapture.startCapture(audioFormat: preferredFormat)
        } catch {
            print("[SubtitleService] Failed to start audio capture: \(error)")
            transcriber.stop()
            return
        }

        captureTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in await self.audioCapture.audioBuffers {
                guard !Task.isCancelled else { break }
                self.transcriber.appendAudioBuffer(buffer)
            }
        }

        isRunning = true
        writeSubtitleState(text: "", status: "listening")
        print("[SubtitleService] Started")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        translationTimer?.cancel()
        translationTimer = nil
        pendingTranslation?.cancel()
        pendingTranslation = nil
        translator = nil
        lastTranslatedInput = ""
        lastTranslationTime = 0

        captureTask?.cancel()
        captureTask = nil
        transcriber.stop()
        await audioCapture.stopCapture()

        subtitlePanel.fadeOut()
        writeSubtitleState(text: "", status: "stopped")
        print("[SubtitleService] Stopped")
    }

    // MARK: - Translation

    private func onNewWords() {
        guard AppSettings.shared.subtitleTranslationLanguage != nil else { return }
        guard subtitlePanel.originalDisplayText.split(separator: " ").count >= 8 else { return }

        // Schedule translation after 3s cooldown
        translationTimer?.cancel()
        let now = Date().timeIntervalSince1970
        let elapsed = now - lastTranslationTime
        let delay = max(0, 3.0 - elapsed)

        translationTimer = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            self.translateNow()
        }
    }

    private func translateNow() {
        guard let targetLang = AppSettings.shared.subtitleTranslationLanguage else { return }
        let now = Date().timeIntervalSince1970
        if now < rateLimitUntil { return }

        let words = subtitlePanel.originalDisplayText.split(separator: " ").map(String.init)
        guard words.count >= 8 else { return }

        let input = words.suffix(15).joined(separator: " ")
        guard input != lastTranslatedInput else { return }

        lastTranslatedInput = input
        lastTranslationTime = now

        print("[Translate] EN: \"\(input)\"")

        if translator == nil {
            guard let apiKey = try? KeychainHelper().load(), !apiKey.isEmpty else { return }
            translator = SubtitleTranslator(apiKey: apiKey)
        }
        guard let translator else { return }

        let model = AppSettings.shared.subtitleTranslationModel
        pendingTranslation?.cancel()

        pendingTranslation = Task {
            do {
                let result = try await translator.translateStreaming(
                    text: input,
                    language: targetLang,
                    model: model,
                    onToken: { _ in }
                )
                guard !Task.isCancelled else { return }
                print("[Translate] RU: \"\(result)\"")

                if !result.isEmpty {
                    self.subtitlePanel.showTranslation(result)
                    self.throttledWriteIPC(text: result)
                }
            } catch {
                if case ClaudeAPIService.APIError.rateLimited = error {
                    self.rateLimitUntil = Date().timeIntervalSince1970 + 30
                    print("[Translate] RATE LIMITED — 30s")
                } else if !(error is CancellationError) {
                    print("[Translate] FAILED: \(error)")
                }
            }
        }
    }

    // MARK: - IPC

    private func throttledWriteIPC(text: String) {
        guard text != lastWrittenText else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastWriteTime >= 0.1 else { return }
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
