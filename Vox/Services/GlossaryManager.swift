import Foundation

/// Owns glossary state (content, generation task, show name, detected topic)
/// and bridges glossary terms into the ASR vocabulary biasing hook.
///
/// The coordinator keeps the `previousLanguage` same-language guard — only it
/// knows the previous selected language, so `startGeneration` is unconditional
/// from this class's point of view.
@MainActor
final class GlossaryManager {
    private(set) var currentGlossary: Glossary?
    private(set) var userProvidedShowName: String?
    private(set) var videoTopic: String?

    private let translatorProvider: @MainActor () -> SubtitleTranslator?
    private let transcriber: LiveTranscriber
    private var generationTask: Task<Void, Never>?

    init(
        translatorProvider: @MainActor @escaping () -> SubtitleTranslator?,
        transcriber: LiveTranscriber
    ) {
        self.translatorProvider = translatorProvider
        self.transcriber = transcriber
    }

    // MARK: - Generation

    /// Starts async glossary generation for the given show. Cancels any
    /// in-flight generation. For user-provided names also seeds `videoTopic`
    /// and `userProvidedShowName` synchronously so readers see the context
    /// before the API call returns.
    func startGeneration(showName: String, isUserProvided: Bool, language: TargetLanguage? = nil) {
        if isUserProvided {
            videoTopic = showName
            userProvidedShowName = showName
        }

        guard let targetLang = language ?? AppSettings.shared.subtitleTranslationLanguage else { return }
        guard let translator = translatorProvider() else { return }

        generationTask?.cancel()
        generationTask = Task {
            print("[Glossary] Generating for \"\(showName)\" (user: \(isUserProvided))...")
            if let glossary = await translator.generateGlossary(
                showName: showName, targetLanguage: targetLang, isUserProvided: isUserProvided
            ) {
                self.currentGlossary = glossary
                let termLines = glossary.content.components(separatedBy: "\n")
                    .filter { $0.contains("→") || $0.contains("—") }
                    .count
                print("[Glossary] Ready: \(glossary.content.count) chars, \(termLines) term lines")
                print("[Glossary] Content preview:\n\(glossary.content.prefix(600))")
                if let hints = glossary.asrHints {
                    print("[Glossary] ASR hints: \(hints.prefix(400))")
                }
                self.pushVocabularyToTranscriber()
            } else {
                print("[Glossary] FAILED for \"\(showName)\"")
            }
        }
    }

    /// Called by the orchestrator after auto-detection in `startFinalTranslation`:
    /// cinema passes both a topic and a freshly-generated glossary; lecture
    /// passes only a topic (glossary = nil).
    func applyAutoDetectedTopic(_ topic: String, glossary: Glossary?) {
        self.videoTopic = topic
        if let glossary {
            self.currentGlossary = glossary
            pushVocabularyToTranscriber()
        }
    }

    /// Called by `processTranslation` when it auto-detects the topic from the
    /// accumulated source text (post-processing path; no glossary involved).
    func setTopicFromPostProcessing(_ topic: String) {
        self.videoTopic = topic
    }

    // MARK: - Reset

    /// Full reset for `stop()` and `switchTranslationMode(to: nil)`.
    func reset() {
        generationTask?.cancel()
        generationTask = nil
        currentGlossary = nil
        userProvidedShowName = nil
        videoTopic = nil
    }

    /// Softer reset for the same-language-change path: clear only the glossary
    /// so it gets regenerated for the new target language. Topic and user
    /// show name survive.
    func resetForLanguageChange() {
        currentGlossary = nil
    }

    /// Clears `videoTopic` only. Coordinator calls this after a successful
    /// language swap so the auto-detection counter in `TranslationOrchestrator`
    /// can rediscover the topic fresh alongside counters/accumulated text.
    func clearDetectedTopic() {
        videoTopic = nil
    }

    // MARK: - ASR Vocabulary

    /// Collects terms from the current glossary + videoTopic and pushes them
    /// into SpeechAnalyzer.contextualStrings to bias recognition. Biasing is
    /// currently DISABLED — see docs/apple-speech-tuning-research.md §8.
    private func pushVocabularyToTranscriber() {
        var words: [String] = []

        // (1) Show name from videoTopic — format "<name>, <genre>, <setting>"
        if let topic = videoTopic {
            let name = topic.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespaces) ?? topic
            if !name.isEmpty { words.append(name) }
        }

        if let glossary = currentGlossary {
            // (2) Left side of each content line — the English term.
            words.append(contentsOf: glossary.englishTerms)

            // (3) Right side of asrHints — the correct spelling.
            //     Format: `"misheard" → "correct", "x" → "y"`
            if let hints = glossary.asrHints {
                for pair in hints.components(separatedBy: ",") {
                    let sides = pair.components(separatedBy: "→")
                    guard sides.count == 2 else { continue }
                    let right = sides[1]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}\u{00AB}\u{00BB}'"))
                        .trimmingCharacters(in: .whitespaces)
                    if !right.isEmpty { words.append(right) }
                }
            }
        }

        // Dedup preserving order, cap at 100 (empirical ceiling from Apple
        // contextualStrings research).
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0.lowercased()).inserted }
        let capped = Array(unique.prefix(100))

        guard !capped.isEmpty else { return }

        // ASR biasing DISABLED — see docs/apple-speech-tuning-research.md §8.
        // Summary: contextualStrings on SpeechTranscriber (macOS 26.1) is
        // silently rejected by EAR worker ("Invalid JIT profile"), and when it
        // does partially apply it shifts ASR toward wrong phonetic neighbors —
        // net negative vs baseline recognition. Translator-side glossary (via
        // Claude prompt) is the only channel that reliably improves quality.
        // Re-enable by uncommenting the line below if Apple fixes runtime
        // setContext for SpeechTranscriber in a future macOS update.
        // transcriber.updateVocabulary(capped)
        _ = transcriber  // retain reference — unused while biasing is disabled
        print("[Vocabulary] Biasing disabled (Phase 1 retrospective). Would have pushed \(capped.count) words.")
    }
}
