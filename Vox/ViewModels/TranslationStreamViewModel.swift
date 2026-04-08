import SwiftUI

@Observable
@MainActor
final class TranslationStreamViewModel {
    private var finalText: String = ""
    private var draftText: String = ""
    var isActive: Bool = false
    var isPolishing: Bool = false
    var selectedLanguage: TargetLanguage = .russian

    /// Full display text: final prefix + draft suffix.
    var accumulatedText: String {
        if finalText.isEmpty && draftText.isEmpty { return "" }
        if finalText.isEmpty { return draftText }
        if draftText.isEmpty { return finalText }
        return finalText + " " + draftText
    }

    /// Character length of the final portion in accumulatedText.
    /// Used by the view to split styling at the right position.
    var finalLength: Int {
        if finalText.isEmpty { return 0 }
        if draftText.isEmpty { return finalText.count }
        return finalText.count + 1 // +1 for the space separator
    }

    /// Update the draft translation (replaces previous draft).
    func updateDraft(_ text: String) {
        draftText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commit a final sentence translation. Appends to finalText, clears draft.
    func commitFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if finalText.isEmpty {
            finalText = trimmed
        } else {
            finalText += " " + trimmed
        }
        draftText = ""
    }

    /// Replace all text (used by Polish button).
    func replaceAll(_ text: String) {
        finalText = text
        draftText = ""
    }

    func clear() {
        finalText = ""
        draftText = ""
    }

    func copyAll() {
        let text = accumulatedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
