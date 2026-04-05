import SwiftUI

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

    // Track if we have a previous result to reshow
    var hasLastResult: Bool { !sourceText.isEmpty }

    private let clipboardService = ClipboardService()
    private let apiService = ClaudeAPIService()
    private let keychainHelper = KeychainHelper()
    private var currentTask: Task<Void, Never>?

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
            if text == sourceText && !translatedText.isEmpty && error == nil {
                showPanel()
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
            targetLanguage = .auto
            showPanel()

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
        targetLanguage = .auto
        showPanel()

        currentTask?.cancel()
        currentTask = Task {
            await runTranslation(text: text, apiKey: apiKey)
        }
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
        NSPasteboard.general.setString(translatedText, forType: .string)
    }

    func dismissPanel() {
        isPanelVisible = false
        currentTask?.cancel()
        currentTask = nil
        onPanelVisibilityChanged?()
    }

    private func showPanel() {
        isPanelVisible = true
        onPanelVisibilityChanged?()
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
            isTranslating = false
        } catch {
            self.error = error.localizedDescription
            isTranslating = false
        }
    }
}
