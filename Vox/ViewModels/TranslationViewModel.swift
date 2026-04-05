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
    var onPanelVisibilityChanged: (() -> Void)?

    private let clipboardService = ClipboardService()
    private let apiService = ClaudeAPIService()
    private let keychainHelper = KeychainHelper()
    private var currentTask: Task<Void, Never>?

    func translateFromClipboard() {
        panelPosition = NSEvent.mouseLocation

        currentTask?.cancel()
        currentTask = Task {
            // Simulate Cmd+C to grab selected text
            guard let text = await clipboardService.copySelectionAndRead() else {
                sourceText = ""
                translatedText = ""
                error = "Nothing to translate — select some text first"
                showPanel()
                return
            }

            guard let apiKey = try? keychainHelper.load(), !apiKey.isEmpty else {
                sourceText = text
                translatedText = ""
                error = "No API key configured. Add your key in Settings."
                showPanel()
                return
            }

            sourceText = text
            translatedText = ""
            error = nil
            isTranslating = true
            showPanel()

            let model = AppSettings.shared.selectedModel

            do {
                let stream = apiService.translate(text: text, model: model, apiKey: apiKey)
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
}
