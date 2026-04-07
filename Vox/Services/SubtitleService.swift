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
    private var lastShownTranslation: String = ""
    private var lastTranslation: (english: String, russian: String)?
    private var rateLimitUntil: TimeInterval = 0

    // Translation stream window
    private var streamViewModel: TranslationStreamViewModel?
    private var streamPanel: TranslationStreamPanel?

    /// The current subtitle language locale identifier (e.g. "en-US", "ru-RU").
    var subtitleLocale: Locale = Locale(identifier: "en-US")

    func start() async {
        guard !isRunning else { return }

        let translationActive = AppSettings.shared.subtitleTranslationLanguage != nil

        transcriber.onSubtitle = { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                if translationActive {
                    // Accumulate words for overlap trimming, but don't show SubtitlePanel
                    if isFinal {
                        self.subtitlePanel.accumulateFinal(text)
                    } else {
                        self.subtitlePanel.accumulateVolatile(text)
                    }
                } else {
                    if isFinal {
                        self.subtitlePanel.showFinal(text)
                    } else {
                        self.subtitlePanel.showVolatile(text)
                    }
                }
                self.throttledWriteIPC(text: self.subtitlePanel.displayText)
                if translationActive {
                    self.onNewWords()
                }
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

        // Open translation stream panel if translation is active
        if translationActive {
            let vm = TranslationStreamViewModel()
            vm.isActive = true
            vm.selectedLanguage = AppSettings.shared.subtitleTranslationLanguage ?? .russian
            streamViewModel = vm

            let panel = TranslationStreamPanel(viewModel: vm)
            panel.onClose = { [weak self] in
                Task { @MainActor in
                    AppSettings.shared.subtitleTranslationLanguage = nil
                    await self?.stop()
                }
            }
            streamPanel = panel
            panel.showCentered()
        }

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
        lastShownTranslation = ""
        lastTranslation = nil

        // Dismiss translation stream
        streamViewModel?.isActive = false
        streamPanel?.dismiss()
        streamViewModel = nil
        streamPanel = nil

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
        let delay = max(0, 4.0 - elapsed)

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

        let rawInput = words.suffix(12).joined(separator: " ")
        guard rawInput != lastTranslatedInput else { return }

        // Strip English overlap with previous input BEFORE sending to model.
        // Model only receives truly new words → can't produce overlap in translation.
        let input = Self.trimEnglishOverlap(new: rawInput, previous: lastTranslatedInput)

        // Need at least 4 words after stripping
        guard input.split(separator: " ").count >= 4 else { return }

        lastTranslatedInput = rawInput
        lastTranslationTime = now

        if input != rawInput {
            print("[Translate] EN raw: \"\(rawInput)\"")
            print("[Translate] EN trimmed: \"\(input)\"")
        } else {
            print("[Translate] EN: \"\(input)\"")
        }

        if translator == nil {
            guard let apiKey = try? KeychainHelper().load(), !apiKey.isEmpty else { return }
            translator = SubtitleTranslator(apiKey: apiKey)
        }
        guard let translator else { return }

        let model = AppSettings.shared.subtitleTranslationModel
        let prevTurn = self.lastTranslation
        pendingTranslation?.cancel()

        // Previous subtitle stays visible until new one arrives — no flicker
        pendingTranslation = Task {
            do {
                let result = try await translator.translateStreaming(
                    text: input,
                    language: targetLang,
                    model: model,
                    previousTurn: prevTurn,
                    onToken: { _ in }
                )
                guard !Task.isCancelled else { return }
                print("[Translate] RU: \"\(result)\"")

                if !result.isEmpty {
                    guard result.split(separator: " ").count >= 3 else {
                        print("[Translate] TOO SHORT — keeping previous")
                        return
                    }
                    self.lastTranslation = (english: input, russian: result)

                    if let vm = self.streamViewModel {
                        vm.append(result)
                    } else {
                        self.subtitlePanel.showTranslation(result)
                    }
                    self.lastShownTranslation = result
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

    // MARK: - English Overlap Trimming (before sending to model)

    /// Strip words from the START of `new` that appear at the END of `previous`.
    /// This removes the sliding-window overlap so the model only translates new content.
    private static func trimEnglishOverlap(new: String, previous: String) -> String {
        guard !previous.isEmpty else { return new }

        // Filter standalone punctuation tokens ("," "." etc.) — they break overlap matching
        func realWords(_ text: String) -> [String] {
            text.split(separator: " ").map(String.init).filter { $0.contains(where: { $0.isLetter }) }
        }

        let newWords = realWords(new)
        let prevWords = realWords(previous)
        let maxOverlap = min(newWords.count, prevWords.count, 10)

        for overlapLen in stride(from: maxOverlap, through: 2, by: -1) {
            let prevSuffix = prevWords.suffix(overlapLen)
            let newPrefix = newWords.prefix(overlapLen)

            let match = zip(prevSuffix, newPrefix).allSatisfy { a, b in
                a.trimmingCharacters(in: .punctuationCharacters).lowercased() ==
                b.trimmingCharacters(in: .punctuationCharacters).lowercased()
            }

            if match {
                let remaining = Array(newWords.dropFirst(overlapLen))
                if remaining.count >= 3 {
                    return remaining.joined(separator: " ")
                }
            }
        }

        return new
    }

    // MARK: - Russian Overlap Trimming (after model response, backup)

    /// Find where the END of `previous` matches the START of `new` and strip it.
    /// "быть ключом к" at end of prev + "быть ключом к квантовой теории" → "квантовой теории"
    private static func trimOverlap(new: String, previous: String) -> String {
        guard !previous.isEmpty else { return new }

        let newWords = new.split(separator: " ").map(String.init)
        let prevWords = previous.split(separator: " ").map(String.init)
        let maxOverlap = min(newWords.count, prevWords.count, 8)

        for overlapLen in stride(from: maxOverlap, through: 2, by: -1) {
            let prevSuffix = prevWords.suffix(overlapLen)
            let newPrefix = newWords.prefix(overlapLen)

            let match = zip(prevSuffix, newPrefix).allSatisfy { a, b in
                Self.fuzzyWordMatch(a, b)
            }

            if match {
                let remaining = Array(newWords.dropFirst(overlapLen))
                if remaining.count >= 2 {
                    return remaining.joined(separator: " ")
                }
            }
        }

        return new
    }

    /// Fuzzy word comparison: handles Russian grammatical suffixes.
    /// "глубокой" ≈ "глубокая", "теории" ≈ "теория"
    private static func fuzzyWordMatch(_ a: String, _ b: String) -> Bool {
        let aNorm = a.trimmingCharacters(in: .punctuationCharacters).lowercased()
        let bNorm = b.trimmingCharacters(in: .punctuationCharacters).lowercased()
        if aNorm == bNorm { return true }
        guard aNorm.count >= 4, bNorm.count >= 4 else { return false }
        // Drop last 2 chars to ignore grammatical endings
        return aNorm.dropLast(2) == bNorm.dropLast(2)
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
