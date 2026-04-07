import SwiftUI

@Observable
@MainActor
final class TranslationStreamViewModel {
    private var refinedText: String = ""
    private var pendingChunks: [String] = []
    var isActive: Bool = false
    var selectedLanguage: TargetLanguage = .russian

    /// Full display text: refined prefix + pending raw chunks.
    var accumulatedText: String {
        if refinedText.isEmpty {
            return pendingChunks.joined(separator: " ")
        } else if pendingChunks.isEmpty {
            return refinedText
        } else {
            return refinedText + " " + pendingChunks.joined(separator: " ")
        }
    }

    /// Number of chunks waiting to be refined.
    var pendingChunksCount: Int { pendingChunks.count }

    /// The pending chunks joined as a single string (sent to refine API).
    var pendingText: String {
        pendingChunks.joined(separator: " ")
    }

    /// Append a raw translated chunk. Returns the new pending count.
    @discardableResult
    func append(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pendingChunks.count }
        pendingChunks.append(trimmed)
        return pendingChunks.count
    }

    /// Replace all pending chunks with refined text.
    func commitRefinedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if refinedText.isEmpty {
            refinedText = trimmed
        } else {
            refinedText += " " + trimmed
        }
        pendingChunks.removeAll()
    }

    /// Get the last N words of refined text (for context in refine API call).
    func refinedTail(maxWords: Int = 30) -> String {
        guard !refinedText.isEmpty else { return "" }
        let words = refinedText.split(separator: " ")
        return words.suffix(maxWords).joined(separator: " ")
    }

    func clear() {
        refinedText = ""
        pendingChunks.removeAll()
    }

    func copyAll() {
        let text = accumulatedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
