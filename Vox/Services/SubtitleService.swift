import Foundation
import AVFoundation

@MainActor
final class SubtitleService {
    private let audioCapture = SystemAudioCapture()
    private let transcriber = LiveTranscriber()
    private let subtitlePanel = SubtitlePanel()
    private let sentenceBuffer = SentenceBuffer()

    private let ipcFile: URL = {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)!
        return container.appendingPathComponent("vox-subtitles.json")
    }()

    private(set) var isRunning = false
    private var captureTask: Task<Void, Never>?
    private var lastWriteTime: TimeInterval = 0
    private var lastWrittenText: String = ""

    // Translation state
    private var translator: SubtitleTranslator?
    private var draftTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var lastFinalTranslation: (english: String, russian: String)?
    private var rateLimitUntil: TimeInterval = 0
    private var videoTopic: String?
    private var translationCount = 0
    private var accumulatedEnglish: [String] = []

    // Translation stream window
    private var streamViewModel: TranslationStreamViewModel?
    private var streamPanel: TranslationStreamPanel?

    var subtitleLocale: Locale = Locale(identifier: "en-US")

    private var translationActive: Bool {
        AppSettings.shared.subtitleTranslationLanguage != nil
    }

    private var displayMode: SubtitleDisplayMode {
        AppSettings.shared.subtitleDisplayMode
    }

    func start() async {
        guard !isRunning else { return }

        sentenceBuffer.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .draftReady(let text):
                self.translateDraft(text)
            case .sentenceComplete(let text):
                self.translateFinal(text)
            }
        }

        transcriber.onSubtitle = { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                if self.translationActive {
                    self.sentenceBuffer.accumulateWords(text, isFinal: isFinal)
                } else {
                    if isFinal {
                        self.subtitlePanel.showFinal(text)
                    } else {
                        self.subtitlePanel.showVolatile(text)
                    }
                }
                if !self.translationActive {
                    self.throttledWriteIPC(text: self.subtitlePanel.displayText)
                }
            }
        }

        transcriber.onSilence = { [weak self] durationMs in
            Task { @MainActor in
                guard let self, self.translationActive else { return }
                self.sentenceBuffer.reportSilence(durationMs: durationMs)
            }
        }

        let initialTranslationActive = translationActive
        await transcriber.start(locale: subtitleLocale, forTranslation: initialTranslationActive)

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

        if initialTranslationActive && displayMode == .lecture {
            openTranslationStream()
        }

        writeSubtitleState(text: "", status: "listening")
        print("[SubtitleService] Started")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        draftTask?.cancel()
        draftTask = nil
        finalTask?.cancel()
        finalTask = nil
        videoTopic = nil
        translationCount = 0
        accumulatedEnglish = []
        translator = nil
        lastFinalTranslation = nil
        sentenceBuffer.reset()

        streamViewModel?.isActive = false
        streamPanel?.onClose = nil
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

    // MARK: - Live Mode Switching

    func switchTranslationMode(to language: TargetLanguage?) {
        AppSettings.shared.subtitleTranslationLanguage = language

        if let language {
            if streamPanel != nil {
                streamViewModel?.selectedLanguage = language
                streamViewModel?.clear()
                lastFinalTranslation = nil
                videoTopic = nil
                translationCount = 0
                accumulatedEnglish = []
                sentenceBuffer.reset()
                draftTask?.cancel()
                draftTask = nil
                finalTask?.cancel()
                finalTask = nil
                print("[SubtitleService] Switched translation language to \(language.rawValue)")
            } else {
                if displayMode == .lecture {
                    openTranslationStream()
                }
                print("[SubtitleService] Translation enabled: \(language.rawValue)")
            }
        } else {
            streamViewModel?.isActive = false
            streamPanel?.onClose = nil
            streamPanel?.dismiss()
            streamViewModel = nil
            streamPanel = nil
            subtitlePanel.clearTranslation()
            draftTask?.cancel()
            draftTask = nil
            finalTask?.cancel()
            finalTask = nil
            translator = nil
            lastFinalTranslation = nil
            videoTopic = nil
            translationCount = 0
            accumulatedEnglish = []
            sentenceBuffer.reset()
            print("[SubtitleService] Translation disabled")
        }
    }

    func switchDisplayMode(to mode: SubtitleDisplayMode) {
        guard mode != AppSettings.shared.subtitleDisplayMode else { return }
        AppSettings.shared.subtitleDisplayMode = mode

        switch mode {
        case .cinema:
            streamViewModel?.isActive = false
            streamPanel?.onClose = nil
            streamPanel?.dismiss()
            streamViewModel = nil
            streamPanel = nil
            subtitlePanel.clearTranslation()
            print("[SubtitleService] Switched to Cinema mode")

        case .lecture:
            subtitlePanel.clearTranslation()
            if translationActive {
                openTranslationStream()
            }
            print("[SubtitleService] Switched to Lecture mode")
        }
    }

    private func openTranslationStream() {
        let vm = TranslationStreamViewModel()
        vm.isActive = true
        vm.selectedLanguage = AppSettings.shared.subtitleTranslationLanguage ?? .russian
        streamViewModel = vm

        let panel = TranslationStreamPanel(viewModel: vm)
        panel.onCustomize = { [weak self] mode in
            self?.processTranslation(mode: mode)
        }
        panel.onClose = { [weak self] in
            Task { @MainActor in
                self?.switchTranslationMode(to: nil)
                await self?.stop()
            }
        }
        streamPanel = panel
        panel.showCentered()
    }

    // MARK: - Process (Polish / Summarize / Study Mode)

    func processTranslation(mode: ProcessingMode) {
        guard let vm = streamViewModel, !vm.accumulatedText.isEmpty else { return }
        guard let targetLang = AppSettings.shared.subtitleTranslationLanguage else { return }
        guard !vm.isProcessing(mode: mode) else { return }

        if translator == nil {
            guard let apiKey = try? KeychainHelper().load(), !apiKey.isEmpty else { return }
            translator = SubtitleTranslator(apiKey: apiKey)
        }
        guard let translator else { return }

        let text = vm.accumulatedText
        let wordCount = text.split(separator: " ").count
        vm.setProcessing(mode, true)

        Task {
            defer { vm.setProcessing(mode, false) }

            if videoTopic == nil {
                let topicSource = accumulatedEnglish.isEmpty ? text : accumulatedEnglish.joined(separator: " ")
                let sourceWordCount = topicSource.split(separator: " ").count
                print("[Topic] Detecting from \(sourceWordCount) words...")
                if let topic = await translator.detectTopic(from: topicSource) {
                    videoTopic = topic
                    print("[Topic] Detected: \"\(topic)\"")
                } else {
                    print("[Topic] FAILED: no result")
                }
            }

            let topicLog = videoTopic.map { "topic: \"\($0)\"" } ?? "no topic"
            print("[\(mode.rawValue)] Sending \(wordCount) words to Sonnet (\(topicLog))")

            let result: String?
            switch mode {
            case .polish:
                result = await translator.polish(text: text, topic: videoTopic, language: targetLang)
            case .summarize:
                result = await translator.summarize(text: text, topic: videoTopic, language: targetLang)
            case .studyMode:
                result = await translator.studyNotes(text: text, topic: videoTopic, language: targetLang)
            }

            if let result {
                let resultWordCount = result.split(separator: " ").count
                print("[\(mode.rawValue)] Done: \(resultWordCount) words returned")
                vm.setTabContent(mode.targetTab, text: result)
                vm.activeTab = mode.targetTab
            } else {
                print("[\(mode.rawValue)] FAILED: no result")
            }
        }
    }

    // MARK: - Draft Translation (Haiku, fast)

    private func translateDraft(_ text: String) {
        guard let targetLang = AppSettings.shared.subtitleTranslationLanguage else { return }
        let now = Date().timeIntervalSince1970
        if now < rateLimitUntil { return }

        guard text.split(separator: " ").count >= 3 else { return }

        draftTask?.cancel()

        if translator == nil {
            guard let apiKey = try? KeychainHelper().load(), !apiKey.isEmpty else { return }
            translator = SubtitleTranslator(apiKey: apiKey)
        }
        guard let translator else { return }

        let prevTurn = lastFinalTranslation
        let currentTopic = videoTopic

        print("[Draft] EN: \"\(text)\"")

        draftTask = Task {
            do {
                let result = try await translator.translateStreaming(
                    text: text,
                    language: targetLang,
                    model: .haiku,
                    previousTurn: prevTurn,
                    topic: currentTopic,
                    onToken: { _ in }
                )
                guard !Task.isCancelled else { return }
                guard !result.isEmpty else { return }
                print("[Draft] \(targetLang.rawValue): \"\(result)\"")
                switch self.displayMode {
                case .lecture:
                    self.streamViewModel?.updateDraft(result)
                case .cinema:
                    self.subtitlePanel.showTranslation(result)
                }
                self.throttledWriteIPC(text: result)
            } catch {
                if case ClaudeAPIService.APIError.rateLimited = error {
                    self.rateLimitUntil = Date().timeIntervalSince1970 + 30
                    print("[Draft] RATE LIMITED — 30s")
                } else if !(error is CancellationError) {
                    print("[Draft] FAILED: \(error)")
                }
            }
        }
    }

    // MARK: - Final Translation (Sonnet, quality)

    private func translateFinal(_ text: String) {
        guard let targetLang = AppSettings.shared.subtitleTranslationLanguage else { return }
        let now = Date().timeIntervalSince1970
        if now < rateLimitUntil { return }

        guard text.split(separator: " ").count >= 2 else { return }

        draftTask?.cancel()

        if translator == nil {
            guard let apiKey = try? KeychainHelper().load(), !apiKey.isEmpty else { return }
            translator = SubtitleTranslator(apiKey: apiKey)
        }
        guard let translator else { return }

        let prevTurn = lastFinalTranslation
        let currentTopic = videoTopic

        print("[Final] EN: \"\(text)\"")

        finalTask = Task {
            do {
                let result = try await translator.translateStreaming(
                    text: text,
                    language: targetLang,
                    model: .sonnet,
                    previousTurn: prevTurn,
                    topic: currentTopic,
                    onToken: { _ in }
                )
                guard !Task.isCancelled else { return }
                guard !result.isEmpty else { return }
                print("[Final] \(targetLang.rawValue): \"\(result)\"")

                self.lastFinalTranslation = (english: text, russian: result)
                switch self.displayMode {
                case .lecture:
                    self.streamViewModel?.commitFinal(result)
                case .cinema:
                    self.subtitlePanel.showTranslation(result)
                }

                self.accumulatedEnglish.append(text)
                self.translationCount += 1
                if self.translationCount == 3, self.videoTopic == nil {
                    let combined = self.accumulatedEnglish.joined(separator: " ")
                    Task {
                        if let topic = await translator.detectTopic(from: combined) {
                            self.videoTopic = topic
                            print("[Topic] Detected: \"\(topic)\"")
                        }
                    }
                }

                self.throttledWriteIPC(text: result)
            } catch {
                if case ClaudeAPIService.APIError.rateLimited = error {
                    self.rateLimitUntil = Date().timeIntervalSince1970 + 30
                    print("[Final] RATE LIMITED — 30s")
                } else if !(error is CancellationError) {
                    print("[Final] FAILED: \(error)")
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
