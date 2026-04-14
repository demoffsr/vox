import Foundation

// MARK: - TranslationRendering

/// Abstraction over the two display surfaces (lecture's `TranslationStreamViewModel`
/// and cinema's `SubtitlePanel`). Owned by `SubtitleService`, passed to the
/// orchestrator as a weak reference.
@MainActor
protocol TranslationRendering: AnyObject {
    var displayMode: SubtitleDisplayMode { get }
    func showDraft(_ text: String)
    func showFinal(_ text: String)
    /// Source-side accumulated text for post-processing. `nil` in cinema mode
    /// (no stream view model) and also when lecture has produced no text yet.
    var accumulatedSourceText: String? { get }
    func setProcessing(_ mode: ProcessingMode, _ active: Bool)
    func isProcessing(_ mode: ProcessingMode) -> Bool
    func setTab(_ tab: StreamTab, text: String)
    func setActiveTab(_ tab: StreamTab)
}

// MARK: - TranslationOrchestrator

/// Owns the draft/final translation pipeline, the cinema queue, the rolling
/// context window, rate-limit bookkeeping, and the polish/summarize/study
/// post-processing path.
///
/// Collaborates with `SubtitleSessionManager` (persistence), `GlossaryManager`
/// (topic + glossary read and auto-detected updates), and `TranslationRendering`
/// (the UI surface). Keyed off the lazy `translatorProvider` shared with the
/// rest of the system so there is exactly one `SubtitleTranslator` per session.
@MainActor
final class TranslationOrchestrator {
    // MARK: - Collaborators

    weak var sessionManager: SubtitleSessionManager?
    weak var glossaryManager: GlossaryManager?
    private weak var renderer: (any TranslationRendering)?

    private let ipcWriter: @MainActor (String) -> Void
    private let translatorProvider: @MainActor () -> SubtitleTranslator?

    // MARK: - Configuration

    /// Phase 2 kill switch — mirrored from `SubtitleService.enableASRCleanup`.
    /// Kept here so the orchestrator's final-translation path can stand alone.
    static let enableASRCleanup = true

    // MARK: - State

    private var draftTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    /// Rolling context: last N translation pairs for multi-turn consistency.
    private var recentTranslations: [(original: String, translated: String)] = []
    private let maxTranslationContext = 5
    /// Cinema: accumulates text from cancelled translations so rapid dialogue
    /// gets batched into the next translation call.
    private var pendingFinalText: String = ""
    private(set) var rateLimitUntil: TimeInterval = 0
    private var translationCount = 0
    private var accumulatedEnglish: [String] = []

    // MARK: - Init

    init(
        renderer: any TranslationRendering,
        ipcWriter: @MainActor @escaping (String) -> Void,
        translatorProvider: @MainActor @escaping () -> SubtitleTranslator?
    ) {
        self.renderer = renderer
        self.ipcWriter = ipcWriter
        self.translatorProvider = translatorProvider
    }

    // MARK: - SentenceBuffer entry points

    /// Called for `.draftReady` events from `SentenceBuffer`. Skipped in cinema
    /// mode (coordinator filters those out — no flicker, fewer API calls).
    func handleDraft(_ text: String) {
        guard let targetLang = AppSettings.shared.subtitleTranslationLanguage else { return }
        let now = Date().timeIntervalSince1970
        if now < rateLimitUntil { return }

        guard text.split(separator: " ").count >= 3 else { return }

        draftTask?.cancel()

        guard let translator = translatorProvider() else { return }

        let prevTurns = recentTranslations
        let currentTopic = glossaryManager?.videoTopic
        let glossarySnapshot = glossaryManager?.currentGlossary

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
                self.renderer?.showDraft(result)
                self.ipcWriter(result)
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

    /// Called for `.sentenceComplete` events from `SentenceBuffer`. Handles
    /// cinema queue semantics (queue on in-flight, recursive drain on success).
    func handleFinal(_ text: String) {
        guard let targetLang = AppSettings.shared.subtitleTranslationLanguage else { return }
        let now = Date().timeIntervalSince1970
        if now < rateLimitUntil { return }

        guard text.split(separator: " ").count >= 2 else { return }

        draftTask?.cancel()

        let isCinema = renderer?.displayMode == .cinema

        if isCinema && finalTask != nil {
            // Cinema: translation in-flight — queue, don't cancel.
            pendingFinalText = pendingFinalText.isEmpty ? text : pendingFinalText + " " + text
            print("[Final] Queued: \"\(text)\"")
            return
        }

        // Include any queued text from rapid dialogue.
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
        guard let translator = translatorProvider() else { return }

        let prevTurns = recentTranslations
        let currentTopic = glossaryManager?.videoTopic
        let glossarySnapshot = glossaryManager?.currentGlossary

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
                self.sessionManager?.appendPair(source: textToTranslate, translated: result)
                self.renderer?.showFinal(result)

                self.accumulatedEnglish.append(text)
                self.translationCount += 1
                let detectAfter = isCinema ? 5 : 3
                if self.translationCount == detectAfter, self.glossaryManager?.videoTopic == nil {
                    let combined = self.accumulatedEnglish.joined(separator: " ")
                    Task {
                        if isCinema, let targetLang = AppSettings.shared.subtitleTranslationLanguage {
                            // Single call: detect topic + generate glossary.
                            if let detected = await translator.detectTopicWithGlossary(
                                from: combined, targetLanguage: targetLang
                            ) {
                                print("[Topic+Glossary] \"\(detected.topic)\", \(detected.glossary.content.count) chars")
                                self.glossaryManager?.applyAutoDetectedTopic(detected.topic, glossary: detected.glossary)
                            }
                        } else {
                            // Lecture: topic only.
                            if let topic = await translator.detectTopic(from: combined) {
                                print("[Topic] Detected: \"\(topic)\"")
                                self.glossaryManager?.applyAutoDetectedTopic(topic, glossary: nil)
                            }
                        }
                    }
                }

                self.ipcWriter(result)

                // Cinema: process any queued dialogue that arrived during translation.
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

    // MARK: - Post-processing (Polish / Summarize / Study)

    func processTranslation(mode: ProcessingMode) {
        guard let renderer else { return }
        guard let source = renderer.accumulatedSourceText, !source.isEmpty else { return }
        guard let targetLang = AppSettings.shared.subtitleTranslationLanguage else { return }
        guard !renderer.isProcessing(mode) else { return }

        guard let translator = translatorProvider() else { return }

        let wordCount = source.split(separator: " ").count
        renderer.setProcessing(mode, true)

        Task {
            defer { renderer.setProcessing(mode, false) }

            if self.glossaryManager?.videoTopic == nil {
                let topicSource = self.accumulatedEnglish.isEmpty
                    ? source
                    : self.accumulatedEnglish.joined(separator: " ")
                let sourceWordCount = topicSource.split(separator: " ").count
                print("[Topic] Detecting from \(sourceWordCount) words...")
                if let topic = await translator.detectTopic(from: topicSource) {
                    self.glossaryManager?.setTopicFromPostProcessing(topic)
                    print("[Topic] Detected: \"\(topic)\"")
                } else {
                    print("[Topic] FAILED: no result")
                }
            }

            let currentTopic = self.glossaryManager?.videoTopic
            let glossarySnapshot = self.glossaryManager?.currentGlossary
            let topicLog = currentTopic.map { "topic: \"\($0)\"" } ?? "no topic"
            print("[\(mode.rawValue)] Sending \(wordCount) words to Sonnet (\(topicLog))")

            let result: String?
            switch mode {
            case .polish:
                result = await translator.polish(text: source, topic: currentTopic, glossary: glossarySnapshot, language: targetLang)
            case .summarize:
                result = await translator.summarize(text: source, topic: currentTopic, language: targetLang)
            case .studyMode:
                result = await translator.studyNotes(text: source, topic: currentTopic, language: targetLang)
            }

            if let result {
                let resultWordCount = result.split(separator: " ").count
                print("[\(mode.rawValue)] Done: \(resultWordCount) words returned")
                renderer.setTab(mode.targetTab, text: result)
                renderer.setActiveTab(mode.targetTab)

                // Attach artifact to the current history session. `activeSessionID`
                // stays alive until `session.finalizeTeardown()` in the coordinator's
                // `stop()`, so late-arriving post-processing calls still land.
                let artifactKind: ArtifactKind = {
                    switch mode {
                    case .polish:    return .polish
                    case .summarize: return .summary
                    case .studyMode: return .studyNotes
                    }
                }()
                self.sessionManager?.attachArtifact(
                    kind: artifactKind,
                    content: result,
                    model: ClaudeModel.sonnet.rawValue
                )
            } else {
                print("[\(mode.rawValue)] FAILED: no result")
            }
        }
    }

    // MARK: - Reset

    /// Full teardown: cancel tasks, zero counters, empty context/queue. Called
    /// from `SubtitleService.stop()` and `switchTranslationMode(to: nil)`.
    func resetAll() {
        draftTask?.cancel()
        draftTask = nil
        finalTask?.cancel()
        finalTask = nil
        pendingFinalText = ""
        recentTranslations = []
        translationCount = 0
        accumulatedEnglish = []
        rateLimitUntil = 0
    }

    /// Lighter reset for the same-language-change path. Preserves rate-limit
    /// state. NOTE: mirrors legacy SubtitleService behavior — the coordinator
    /// only invokes this when `streamPanel != nil`, so cinema language changes
    /// currently skip this reset (known issue, out of scope for this refactor).
    func resetForLanguageChange() {
        draftTask?.cancel()
        draftTask = nil
        finalTask?.cancel()
        finalTask = nil
        recentTranslations = []
        translationCount = 0
        accumulatedEnglish = []
    }
}
