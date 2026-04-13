import SwiftUI
import NaturalLanguage

@Observable
@MainActor
final class TranslationViewModel {
    var sourceText: String = ""
    var translatedText: String = ""
    var isTranslating: Bool = false
    var error: String?
    var isPanelVisible: Bool = false
    var panelPosition: CGPoint = .zero
    var targetLanguage: TargetLanguage = .auto
    var onPanelVisibilityChanged: (() -> Void)?

    // Smart Look Up state
    var activeTab: LookUpTab = .translation
    var lookUpData: LookUpData?
    var isLoadingLookUp: Bool = false

    // Image search state
    var imageData: [ImageItem] = []
    var isLoadingImages: Bool = false

    // Track if we have a previous result to reshow
    var hasLastResult: Bool { !sourceText.isEmpty }

    var visibleTabs: [LookUpTab] {
        guard AppSettings.shared.smartModeEnabled else { return [.translation] }
        if isLoadingLookUp || isLoadingImages { return LookUpTab.allCases }
        var tabs: [LookUpTab] = [.translation]
        if let data = lookUpData {
            if data.dictionary != nil { tabs.append(.dictionary) }
            if data.context != nil { tabs.append(.context) }
        }
        if !imageData.isEmpty { tabs.append(.images) }
        return tabs
    }

    /// Returns the text to copy based on the active tab.
    var copyableText: String {
        switch activeTab {
        case .translation:
            return translatedText
        case .dictionary:
            guard let dict = lookUpData?.dictionary else { return "" }
            var lines = [dict.partOfSpeech]
            if let pron = dict.pronunciation { lines.append(pron) }
            for (i, entry) in dict.entries.enumerated() {
                lines.append("\(i + 1). \(entry.meaning)")
                if let ex = entry.example { lines.append("   \(ex)") }
            }
            return lines.joined(separator: "\n")
        case .context:
            guard let ctx = lookUpData?.context else { return "" }
            var lines: [String] = []
            if !ctx.synonyms.isEmpty {
                lines.append(ctx.synonyms.map { "\($0.word) (\($0.note))" }.joined(separator: ", "))
            }
            if !ctx.collocations.isEmpty {
                lines.append("Collocations: " + ctx.collocations.joined(separator: ", "))
            }
            for ff in ctx.falseFriends {
                lines.append("\(ff.word) \u{2192} \(ff.meaning)")
            }
            for note in ctx.notes { lines.append(note) }
            return lines.joined(separator: "\n")
        case .images:
            return imageData.map { item in
                let url = (item.fullImageURL ?? item.imageURL).absoluteString
                return "\(item.title)\n\(url)"
            }.joined(separator: "\n\n")
        }
    }

    private let clipboardService = ClipboardService()
    private let apiService = ClaudeAPIService()
    private let imageService = ImageSearchService()
    private let keychainHelper = KeychainHelper()
    private var currentTask: Task<Void, Never>?
    private var lookUpTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var lookUpSourceText: String?
    private var imageSourceText: String?

    /// History persistence. Injected after init (set by `AppDelegate`).
    /// Nil means translations are not saved (fail-soft for tests / previews).
    weak var historyStore: HistoryStore?
    /// When the user re-runs `runTranslation` on the same source (retranslate
    /// to a different target language), we update this existing entry in-place
    /// instead of creating a duplicate.
    private var lastSavedEntryID: UUID?
    private var lastSavedSourceText: String?

    func translateFromClipboard() {
        panelPosition = NSEvent.mouseLocation

        currentTask?.cancel()
        currentTask = Task {
            guard let text = await clipboardService.copySelectionAndRead() else {
                // No selection — show last result if available
                if hasLastResult {
                    showPanel()
                } else {
                    sourceText = ""
                    translatedText = ""
                    error = "Select some text and press ⌘T"
                    showPanel()
                }
                return
            }

            // If same text as before, just re-show the panel
            // But still fire lookup if smart mode was toggled on since last time
            if text == sourceText && !translatedText.isEmpty && error == nil {
                showPanel()
                if let apiKey = try? keychainHelper.load(), !apiKey.isEmpty {
                    startLookUpIfNeeded(text: text, apiKey: apiKey)
                }
                return
            }

            guard let apiKey = try? keychainHelper.load(), !apiKey.isEmpty else {
                sourceText = text
                translatedText = ""
                error = "No API key — add it in Settings"
                showPanel()
                return
            }

            sourceText = text
            translatedText = ""
            error = nil
            isTranslating = true
            targetLanguage = resolvedAutoTarget(for: text)
            showPanel()

            // Start lookup in parallel with translation so it's not blocked/cancelled
            startLookUpIfNeeded(text: text, apiKey: apiKey)
            await runTranslation(text: text, apiKey: apiKey)
        }
    }

    /// Re-translate same text with a different target language
    func retranslate(to language: TargetLanguage) {
        guard !sourceText.isEmpty else { return }
        guard let apiKey = try? keychainHelper.load(), !apiKey.isEmpty else { return }

        targetLanguage = language
        translatedText = ""
        error = nil
        isTranslating = true

        currentTask?.cancel()
        currentTask = Task {
            await runTranslation(text: sourceText, apiKey: apiKey)
        }

        if AppSettings.shared.smartModeEnabled {
            lookUpData = nil
            lookUpTask?.cancel()
            lookUpTask = Task {
                await runLookUp(text: sourceText, apiKey: apiKey)
            }
            // Images don't depend on target language — keep cached
        }
    }

    /// Translate text directly (from Services menu — no clipboard needed)
    func translateDirectly(text: String) {
        panelPosition = NSEvent.mouseLocation

        guard let apiKey = try? keychainHelper.load(), !apiKey.isEmpty else {
            sourceText = text
            translatedText = ""
            error = "No API key — add it in Settings"
            showPanel()
            return
        }

        sourceText = text
        translatedText = ""
        error = nil
        isTranslating = true
        targetLanguage = resolvedAutoTarget(for: text)
        showPanel()

        currentTask?.cancel()
        currentTask = Task {
            await runTranslation(text: text, apiKey: apiKey)
        }
        startLookUpIfNeeded(text: text, apiKey: apiKey)
    }

    /// Show last result without new translation
    func showLastResult() {
        if hasLastResult {
            panelPosition = NSEvent.mouseLocation
            showPanel()
        }
    }

    func copyTranslation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableText, forType: .string)
    }

    func dismissPanel() {
        isPanelVisible = false
        currentTask?.cancel()
        currentTask = nil
        lookUpTask?.cancel()
        lookUpTask = nil
        imageTask?.cancel()
        imageTask = nil
        activeTab = .translation
        onPanelVisibilityChanged?()
    }

    private func showPanel() {
        isPanelVisible = true
        onPanelVisibilityChanged?()
    }

    /// Detects the source language locally and picks the appropriate target
    /// based on the user's primary/secondary preferences. Replaces the old
    /// hard-coded RU↔EN `.auto` behavior.
    private func resolvedAutoTarget(for text: String) -> TargetLanguage {
        let detected = LanguageDetector.detect(text: text)
        return LanguageDetector.resolveTarget(
            for: detected,
            primary: AppSettings.shared.primaryTargetLanguage,
            secondary: AppSettings.shared.secondaryTargetLanguage
        )
    }

    private func runTranslation(text: String, apiKey: String) async {
        let model = AppSettings.shared.selectedModel
        do {
            let stream = apiService.translate(
                text: text,
                model: model,
                apiKey: apiKey,
                targetLanguage: targetLanguage
            )
            for try await chunk in stream {
                translatedText += chunk
            }
            // Strip closing tag from assistant prefill if present
            if translatedText.hasSuffix("</translation>") {
                translatedText = String(translatedText.dropLast("</translation>".count))
            }
            translatedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            isTranslating = false
            persistToHistory(model: model, apiKey: apiKey)
        } catch {
            self.error = error.localizedDescription
            isTranslating = false
        }
    }

    // MARK: - Smart Look Up

    private func startLookUpIfNeeded(text: String, apiKey: String) {
        guard AppSettings.shared.smartModeEnabled else { return }

        let isURL = ImageSearchService.looksLikeURL(text)

        // Claude lookup (dictionary + context + imageSearchQuery)
        if text != lookUpSourceText || lookUpData == nil {
            lookUpData = nil
            lookUpSourceText = nil
            imageData = []
            imageSourceText = nil
            activeTab = .translation
            lookUpTask?.cancel()
            imageTask?.cancel()
            lookUpTask = Task {
                await runLookUp(text: text, apiKey: apiKey)
            }
        }

        // For URLs: skip Claude's imageSearchQuery, fetch OG preview directly
        if isURL, text != imageSourceText {
            imageData = []
            imageSourceText = nil
            imageTask?.cancel()
            imageTask = Task {
                await runLinkPreview(text: text)
            }
        }
    }

    private func runLookUp(text: String, apiKey: String) async {
        isLoadingLookUp = true
        var imageQuery: String?
        do {
            let data = try await apiService.lookUp(
                text: String(text.prefix(500)),
                targetLanguage: targetLanguage,
                apiKey: apiKey
            )
            lookUpData = data
            lookUpSourceText = text
            imageQuery = data.imageSearchQuery
        } catch {
            print("[LookUp] Error: \(error)")
            lookUpData = nil
        }
        isLoadingLookUp = false

        // Use Claude's suggested query, or fall back to source text
        let query = (imageQuery?.isEmpty == false) ? imageQuery! : text
        if imageSourceText != text {
            imageTask?.cancel()
            imageTask = Task {
                await runImageSearch(query: query, sourceText: text)
            }
        }
    }

    private func runImageSearch(query: String, sourceText: String) async {
        isLoadingImages = true
        let items = await imageService.searchImages(query: query)
        imageData = items
        imageSourceText = sourceText
        isLoadingImages = false
    }

    private func runLinkPreview(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return }
        isLoadingImages = true
        if let item = await imageService.fetchLinkPreview(url: url) {
            imageData = [item]
        }
        imageSourceText = text
        isLoadingImages = false
    }

    /// Writes the current source/translated pair to the history store.
    /// Reuses `lastSavedEntryID` when the source text matches the previously
    /// saved entry — that's the `retranslate(to:)` path, where the user changed
    /// only the target language and we want to update in-place instead of
    /// spawning a duplicate row.
    private func persistToHistory(model: ClaudeModel, apiKey: String) {
        guard let store = historyStore,
              error == nil,
              !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        if let lastID = lastSavedEntryID, lastSavedSourceText == sourceText {
            store.updateQuickTranslation(
                entryID: lastID,
                translated: translatedText,
                targetLang: targetLanguage.rawValue
            )
            return
        }

        let sourceLang = LanguageDetector.detect(text: sourceText)?.rawValue
        guard let newID = store.saveQuickTranslation(
            source: sourceText,
            translated: translatedText,
            sourceLang: sourceLang,
            targetLang: targetLanguage.rawValue,
            model: model.rawValue
        ) else { return }

        lastSavedEntryID = newID
        lastSavedSourceText = sourceText

        Task { [weak store] in
            await store?.generateTitleIfNeeded(entryID: newID)
        }
    }
}
