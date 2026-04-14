import Foundation
import AVFoundation

@MainActor
final class SubtitleService {
    // Phase 2 kill switch — flip to false and rebuild to disable the ASR
    // cleanup stage. See docs/apple-speech-tuning-research.md §8 and
    // docs/superpowers/specs/2026-04-10-asr-cleanup-design.md.
    static let enableASRCleanup = true

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

    // History persistence (injected by AppDelegate).
    weak var historyStore: HistoryStore? {
        didSet { session.historyStore = historyStore }
    }
    private let session = SubtitleSessionManager()

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
    private var translationCount = 0
    private var accumulatedEnglish: [String] = []

    private lazy var glossary: GlossaryManager = GlossaryManager(
        translatorProvider: { [weak self] in self?.ensureTranslator() },
        transcriber: transcriber
    )

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

    /// Lazy factory shared by the coordinator, `GlossaryManager`, and (in Step 3)
    /// `TranslationOrchestrator`. Ensures exactly one `SubtitleTranslator` per
    /// session and exactly one Keychain read.
    private func ensureTranslator() -> SubtitleTranslator? {
        if let translator { return translator }
        guard let apiKey = try? KeychainHelper().load(), !apiKey.isEmpty else { return nil }
        let created = SubtitleTranslator(apiKey: apiKey)
        translator = created
        return created
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

        // Create a history entry for this session. We write pairs as they
        // arrive in translateFinal's success branch; the transcript blob
        // is flushed periodically and finalized in stop().
        let kind: HistoryKind = (displayMode == .cinema) ? .cinemaSession : .lectureSession
        session.beginSession(
            kind: kind,
            targetLang: (AppSettings.shared.subtitleTranslationLanguage?.rawValue) ?? "",
            model: (displayMode == .cinema ? ClaudeModel.haiku : ClaudeModel.sonnet).rawValue,
            showName: glossary.userProvidedShowName
        )

        if initialTranslationActive && displayMode == .lecture {
            openTranslationStream()
        }

        // Show the overlay immediately so the user sees feedback before the first
        // transcribed word. The panel stays visible for the lifetime of the session —
        // no auto-fade — and is hidden only by stop() below.
        if AppSettings.shared.showNativeSubtitles {
            subtitlePanel.activate()
        }

        writeSubtitleState(text: "", status: "listening")
        print("[SubtitleService] Started")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        // Finalize or drop the history session before any per-session state
        // is cleared. Keep `activeSessionID` alive until the very end so a
        // late `processTranslation` artifact can still attach to it —
        // `session.endSession` writes the blob but does NOT null out the ID;
        // `session.finalizeTeardown()` does, called last below.
        session.endSession(glossaryContent: glossary.currentGlossary?.content)

        draftTask?.cancel()
        draftTask = nil
        finalTask?.cancel()
        finalTask = nil
        pendingFinalText = ""
        translationCount = 0
        accumulatedEnglish = []
        glossary.reset()
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

        // Drop history session state last — post-processing artifacts in
        // `processTranslation` check `activeSessionID` and we want any
        // late-arriving callbacks to land on the correct entry.
        session.finalizeTeardown()
    }

    // MARK: - Live Mode Switching

    func switchTranslationMode(to language: TargetLanguage?) {
        let previousLanguage = AppSettings.shared.subtitleTranslationLanguage
        AppSettings.shared.subtitleTranslationLanguage = language

        if let language {
            // Regenerate glossary ONLY if the language actually changed — otherwise
            // a redundant "same language" tap from the menu would cancel an in-flight
            // glossary retry and restart from scratch.
            let languageChanged = previousLanguage != language
            let isUserProvided = glossary.userProvidedShowName != nil
            let glossaryShowName = glossary.userProvidedShowName ?? glossary.videoTopic
            if languageChanged {
                glossary.resetForLanguageChange()
                if let glossaryShowName {
                    startGlossaryGeneration(showName: glossaryShowName, isUserProvided: isUserProvided, language: language)
                }
            }

            if streamPanel != nil {
                streamViewModel?.selectedLanguage = language
                streamViewModel?.clear()
                recentTranslations = []
                glossary.clearDetectedTopic()
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
            translationCount = 0
            accumulatedEnglish = []
            glossary.reset()
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
        glossary.startGeneration(showName: showName, isUserProvided: isUserProvided, language: language)
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

        guard let translator = ensureTranslator() else { return }

        let text = vm.accumulatedText
        let wordCount = text.split(separator: " ").count
        vm.setProcessing(mode, true)

        Task {
            defer { vm.setProcessing(mode, false) }

            if glossary.videoTopic == nil {
                let topicSource = accumulatedEnglish.isEmpty ? text : accumulatedEnglish.joined(separator: " ")
                let sourceWordCount = topicSource.split(separator: " ").count
                print("[Topic] Detecting from \(sourceWordCount) words...")
                if let topic = await translator.detectTopic(from: topicSource) {
                    glossary.setTopicFromPostProcessing(topic)
                    print("[Topic] Detected: \"\(topic)\"")
                } else {
                    print("[Topic] FAILED: no result")
                }
            }

            let currentTopic = glossary.videoTopic
            let topicLog = currentTopic.map { "topic: \"\($0)\"" } ?? "no topic"
            print("[\(mode.rawValue)] Sending \(wordCount) words to Sonnet (\(topicLog))")

            let result: String?
            switch mode {
            case .polish:
                result = await translator.polish(text: text, topic: currentTopic, glossary: glossary.currentGlossary, language: targetLang)
            case .summarize:
                result = await translator.summarize(text: text, topic: currentTopic, language: targetLang)
            case .studyMode:
                result = await translator.studyNotes(text: text, topic: currentTopic, language: targetLang)
            }

            if let result {
                let resultWordCount = result.split(separator: " ").count
                print("[\(mode.rawValue)] Done: \(resultWordCount) words returned")
                vm.setTabContent(mode.targetTab, text: result)
                vm.activeTab = mode.targetTab

                // Attach the artifact to the current history session.
                // `session.activeSessionID` stays alive until stop() finishes
                // (two-phase teardown), so late-arriving post-processing calls
                // still land correctly.
                let artifactKind: ArtifactKind = {
                    switch mode {
                    case .polish:    return .polish
                    case .summarize: return .summary
                    case .studyMode: return .studyNotes
                    }
                }()
                session.attachArtifact(
                    kind: artifactKind,
                    content: result,
                    model: ClaudeModel.sonnet.rawValue
                )
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

        guard let translator = ensureTranslator() else { return }

        let prevTurns = recentTranslations
        let currentTopic = glossary.videoTopic
        let glossarySnapshot = glossary.currentGlossary

        print("[Draft] EN: \"\(text)\"")

        draftTask = Task {
            do {
                let result = try await translator.translateStreaming(
                    text: text,
                    language: targetLang,
                    model: .haiku,
                    previousTurns: prevTurns,
                    topic: currentTopic,
                    glossary: glossarySnapshot,
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
                } else if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
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
        guard let translator = ensureTranslator() else { return }

        let prevTurns = recentTranslations
        let currentTopic = glossary.videoTopic
        let glossarySnapshot = glossary.currentGlossary

        print("[Final] EN: \"\(text)\" (context: \(prevTurns.count) turns)")

        finalTask = Task {
            defer { self.finalTask = nil }
            do {
                // Phase 2: ASR cleanup stage. Runs only when a glossary is
                // available for this session (cinema-only in practice; lecture
                // mode never generates a glossary). Any failure inside
                // correctASRTerms returns the original text — cancellation
                // rethrows so the outer catch handles it.
                var textToTranslate = text
                if Self.enableASRCleanup, let glossarySnapshot {
                    textToTranslate = try await translator.correctASRTerms(
                        text: text, glossary: glossarySnapshot, topic: currentTopic
                    )
                }

                let finalModel: ClaudeModel = isCinema ? .haiku : .sonnet
                let result = try await translator.translateStreaming(
                    text: textToTranslate,
                    language: targetLang,
                    model: finalModel,
                    previousTurns: prevTurns,
                    topic: currentTopic,
                    glossary: glossarySnapshot,
                    cinemaMode: isCinema,
                    onToken: { _ in }
                )
                guard !Task.isCancelled else { return }
                guard !result.isEmpty else { return }
                print("[Final] \(targetLang.rawValue): \"\(result)\"")

                self.recentTranslations.append((original: textToTranslate, translated: result))
                if self.recentTranslations.count > self.maxTranslationContext {
                    self.recentTranslations.removeFirst()
                }

                // Persist the pair to history (works for both lecture and cinema).
                self.session.appendPair(source: textToTranslate, translated: result)
                switch self.displayMode {
                case .lecture:
                    self.streamViewModel?.commitFinal(result)
                case .cinema:
                    self.subtitlePanel.showTranslation(result)
                }

                self.accumulatedEnglish.append(text)
                self.translationCount += 1
                let detectAfter = isCinema ? 5 : 3
                if self.translationCount == detectAfter, self.glossary.videoTopic == nil {
                    let combined = self.accumulatedEnglish.joined(separator: " ")
                    Task {
                        if isCinema, let targetLang = AppSettings.shared.subtitleTranslationLanguage {
                            // Single call: detect topic + generate glossary
                            if let detected = await translator.detectTopicWithGlossary(
                                from: combined, targetLanguage: targetLang
                            ) {
                                print("[Topic+Glossary] \"\(detected.topic)\", \(detected.glossary.content.count) chars")
                                self.glossary.applyAutoDetectedTopic(detected.topic, glossary: detected.glossary)
                            }
                        } else {
                            // Lecture: topic only
                            if let topic = await translator.detectTopic(from: combined) {
                                print("[Topic] Detected: \"\(topic)\"")
                                self.glossary.applyAutoDetectedTopic(topic, glossary: nil)
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
                } else if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
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
