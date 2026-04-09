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
    /// Rolling context: last N translation pairs for multi-turn consistency
    private var recentTranslations: [(original: String, translated: String)] = []
    private let maxTranslationContext = 5
    /// Cinema: accumulates text from cancelled translations so rapid dialogue gets batched
    private var pendingFinalText: String = ""
    private var rateLimitUntil: TimeInterval = 0
    private var videoTopic: String?
    private var translationCount = 0
    private var accumulatedEnglish: [String] = []
    // Glossary state
    private var currentGlossary: Glossary?
    private var glossaryTask: Task<Void, Never>?
    private var userProvidedShowName: String?

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
                // Cinema: skip drafts — only finals (pop-on, no flicker, fewer API calls)
                if self.displayMode != .cinema {
                    self.translateDraft(text)
                }
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
        transcriber.cinemaMode = displayMode == .cinema
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
        pendingFinalText = ""
        videoTopic = nil
        translationCount = 0
        accumulatedEnglish = []
        currentGlossary = nil
        glossaryTask?.cancel()
        glossaryTask = nil
        userProvidedShowName = nil
        translator = nil
        recentTranslations = []
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
            // Regenerate glossary for new language (works in both cinema and lecture)
            let glossaryShowName = userProvidedShowName ?? videoTopic
            currentGlossary = nil
            if let glossaryShowName {
                startGlossaryGeneration(showName: glossaryShowName, isUserProvided: userProvidedShowName != nil, language: language)
            }

            if streamPanel != nil {
                streamViewModel?.selectedLanguage = language
                streamViewModel?.clear()
                recentTranslations = []
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
            pendingFinalText = ""
            translator = nil
            recentTranslations = []
            videoTopic = nil
            translationCount = 0
            accumulatedEnglish = []
            currentGlossary = nil
            glossaryTask?.cancel()
            glossaryTask = nil
            userProvidedShowName = nil
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

    // MARK: - Glossary

    func startGlossaryGeneration(showName: String, isUserProvided: Bool, language: TargetLanguage? = nil) {
        if isUserProvided {
            videoTopic = showName
            userProvidedShowName = showName
        }

        guard let targetLang = language ?? AppSettings.shared.subtitleTranslationLanguage else { return }

        if translator == nil {
            guard let apiKey = try? KeychainHelper().load(), !apiKey.isEmpty else { return }
            translator = SubtitleTranslator(apiKey: apiKey)
        }
        guard let translator else { return }

        glossaryTask?.cancel()
        glossaryTask = Task {
            print("[Glossary] Generating for \"\(showName)\" (user: \(isUserProvided))...")
            if let glossary = await translator.generateGlossary(
                showName: showName, targetLanguage: targetLang, isUserProvided: isUserProvided
            ) {
                self.currentGlossary = glossary
                print("[Glossary] Ready: \(glossary.content.count) chars")
            } else {
                print("[Glossary] FAILED for \"\(showName)\"")
            }
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
                result = await translator.polish(text: text, topic: videoTopic, glossary: currentGlossary, language: targetLang)
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

        let prevTurns = recentTranslations
        let currentTopic = videoTopic
        let glossary = currentGlossary

        print("[Draft] EN: \"\(text)\"")

        draftTask = Task {
            do {
                let result = try await translator.translateStreaming(
                    text: text,
                    language: targetLang,
                    model: .haiku,
                    previousTurns: prevTurns,
                    topic: currentTopic,
                    glossary: glossary,
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

    // MARK: - Final Translation (Sonnet for lecture, Haiku for cinema)

    private func translateFinal(_ text: String) {
        guard let targetLang = AppSettings.shared.subtitleTranslationLanguage else { return }
        let now = Date().timeIntervalSince1970
        if now < rateLimitUntil { return }

        guard text.split(separator: " ").count >= 2 else { return }

        draftTask?.cancel()

        let isCinema = displayMode == .cinema

        if isCinema && finalTask != nil {
            // Cinema: translation in-flight — queue, don't cancel
            pendingFinalText = pendingFinalText.isEmpty ? text : pendingFinalText + " " + text
            print("[Final] Queued: \"\(text)\"")
            return
        }

        // Include any queued text from rapid dialogue
        let textToTranslate: String
        if isCinema && !pendingFinalText.isEmpty {
            textToTranslate = pendingFinalText + " " + text
            pendingFinalText = ""
        } else {
            textToTranslate = text
        }

        startFinalTranslation(textToTranslate, targetLang: targetLang, isCinema: isCinema)
    }

    private func startFinalTranslation(_ text: String, targetLang: TargetLanguage, isCinema: Bool) {
        if translator == nil {
            guard let apiKey = try? KeychainHelper().load(), !apiKey.isEmpty else { return }
            translator = SubtitleTranslator(apiKey: apiKey)
        }
        guard let translator else { return }

        let prevTurns = recentTranslations
        let currentTopic = videoTopic
        let glossary = currentGlossary

        print("[Final] EN: \"\(text)\" (context: \(prevTurns.count) turns)")

        finalTask = Task {
            defer { self.finalTask = nil }
            do {
                let finalModel: ClaudeModel = isCinema ? .haiku : .sonnet
                let result = try await translator.translateStreaming(
                    text: text,
                    language: targetLang,
                    model: finalModel,
                    previousTurns: prevTurns,
                    topic: currentTopic,
                    glossary: glossary,
                    cinemaMode: isCinema,
                    onToken: { _ in }
                )
                guard !Task.isCancelled else { return }
                guard !result.isEmpty else { return }
                print("[Final] \(targetLang.rawValue): \"\(result)\"")

                self.recentTranslations.append((original: text, translated: result))
                if self.recentTranslations.count > self.maxTranslationContext {
                    self.recentTranslations.removeFirst()
                }
                switch self.displayMode {
                case .lecture:
                    self.streamViewModel?.commitFinal(result)
                case .cinema:
                    self.subtitlePanel.showTranslation(result)
                }

                self.accumulatedEnglish.append(text)
                self.translationCount += 1
                let detectAfter = isCinema ? 5 : 3
                if self.translationCount == detectAfter, self.videoTopic == nil {
                    let combined = self.accumulatedEnglish.joined(separator: " ")
                    Task {
                        if isCinema, let targetLang = AppSettings.shared.subtitleTranslationLanguage {
                            // Single call: detect topic + generate glossary
                            if let result = await translator.detectTopicWithGlossary(
                                from: combined, targetLanguage: targetLang
                            ) {
                                self.videoTopic = result.topic
                                self.currentGlossary = result.glossary
                                print("[Topic+Glossary] \"\(result.topic)\", \(result.glossary.content.count) chars")
                            }
                        } else {
                            // Lecture: topic only
                            if let topic = await translator.detectTopic(from: combined) {
                                self.videoTopic = topic
                                print("[Topic] Detected: \"\(topic)\"")
                            }
                        }
                    }
                }

                self.throttledWriteIPC(text: result)

                // Cinema: process any queued dialogue that arrived during translation
                if isCinema && !self.pendingFinalText.isEmpty {
                    let queued = self.pendingFinalText
                    self.pendingFinalText = ""
                    self.startFinalTranslation(queued, targetLang: targetLang, isCinema: true)
                }
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
