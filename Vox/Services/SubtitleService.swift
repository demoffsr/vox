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

    // History persistence (injected by AppDelegate).
    weak var historyStore: HistoryStore? {
        didSet { session.historyStore = historyStore }
    }
    private let session = SubtitleSessionManager()

    /// Lazy `SubtitleTranslator` — one instance per session. Held here (not in
    /// the sub-modules) so all callers share the same API-key load.
    private var translator: SubtitleTranslator?

    private lazy var glossary: GlossaryManager = GlossaryManager(
        translatorProvider: { [weak self] in self?.ensureTranslator() },
        transcriber: transcriber
    )

    private lazy var orchestrator: TranslationOrchestrator = {
        let o = TranslationOrchestrator(
            renderer: self,
            ipcWriter: { [weak self] text in self?.throttledWriteIPC(text: text) },
            translatorProvider: { [weak self] in self?.ensureTranslator() }
        )
        o.sessionManager = session
        o.glossaryManager = glossary
        return o
    }()

    // Translation stream window
    private var streamViewModel: TranslationStreamViewModel?
    private var streamPanel: TranslationStreamPanel?

    var subtitleLocale: Locale = Locale(identifier: "en-US")

    private var translationActive: Bool {
        AppSettings.shared.subtitleTranslationLanguage != nil
    }

    var displayMode: SubtitleDisplayMode {
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
                    self.orchestrator.handleDraft(text)
                }
            case .sentenceComplete(let text):
                self.orchestrator.handleFinal(text)
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

        // Teardown order is deliberate — see plan Step 3.7:
        //   1. stop audio/ASR so no new sentences arrive
        //   2. session.endSession — writes/deletes the entry but keeps
        //      activeSessionID alive for late post-processing callbacks
        //   3. orchestrator.resetAll — cancels in-flight translation tasks
        //   4. glossary.reset — cancels glossary generation + clears state
        //   5. UI cleanup (stream panel, subtitle panel, IPC)
        //   6. session.finalizeTeardown — NOW it's safe to null activeSessionID
        captureTask?.cancel()
        captureTask = nil
        transcriber.stop()
        await audioCapture.stopCapture()

        session.endSession(glossaryContent: glossary.currentGlossary?.content)

        orchestrator.resetAll()
        glossary.reset()
        translator = nil
        sentenceBuffer.reset()

        streamViewModel?.isActive = false
        streamPanel?.onClose = nil
        streamPanel?.dismiss()
        streamViewModel = nil
        streamPanel = nil

        subtitlePanel.fadeOut()
        writeSubtitleState(text: "", status: "stopped")
        print("[SubtitleService] Stopped")

        // Drop history session state last — post-processing artifacts in
        // `orchestrator.processTranslation` check `activeSessionID` and we want
        // any late-arriving callbacks to land on the correct entry.
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
                glossary.clearDetectedTopic()
                orchestrator.resetForLanguageChange()
                sentenceBuffer.reset()
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
            orchestrator.resetAll()
            translator = nil
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
            self?.orchestrator.processTranslation(mode: mode)
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

// MARK: - TranslationRendering

/// `SubtitleService` is the single rendering surface for both modes. Lecture
/// routes through `TranslationStreamViewModel`; cinema goes straight to
/// `SubtitlePanel`. `accumulatedSourceText` is only meaningful in lecture
/// (cinema has no stream view model to aggregate source text into).
extension SubtitleService: TranslationRendering {
    func showDraft(_ text: String) {
        switch displayMode {
        case .lecture: streamViewModel?.updateDraft(text)
        case .cinema:  subtitlePanel.showTranslation(text)
        }
    }

    func showFinal(_ text: String) {
        switch displayMode {
        case .lecture: streamViewModel?.commitFinal(text)
        case .cinema:  subtitlePanel.showTranslation(text)
        }
    }

    var accumulatedSourceText: String? {
        streamViewModel?.accumulatedText
    }

    func setProcessing(_ mode: ProcessingMode, _ active: Bool) {
        streamViewModel?.setProcessing(mode, active)
    }

    func isProcessing(_ mode: ProcessingMode) -> Bool {
        streamViewModel?.isProcessing(mode: mode) ?? false
    }

    func setTab(_ tab: StreamTab, text: String) {
        streamViewModel?.setTabContent(tab, text: text)
    }

    func setActiveTab(_ tab: StreamTab) {
        streamViewModel?.activeTab = tab
    }
}
