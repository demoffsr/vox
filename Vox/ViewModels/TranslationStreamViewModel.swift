import SwiftUI

@Observable
@MainActor
final class TranslationStreamViewModel {
    private(set) var chunks: [String] = []
    var isActive: Bool = false
    var selectedLanguage: TargetLanguage = .russian

    var accumulatedText: String {
        chunks.joined(separator: " ")
    }

    /// Append a translated chunk. Returns the chunk index, or nil if text was empty.
    @discardableResult
    func append(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        chunks.append(trimmed)
        return chunks.count - 1
    }

    /// Replace a chunk at the given index (used by cleanup post-processing).
    func replaceChunk(at index: Int, with text: String) {
        guard index >= 0, index < chunks.count else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chunks[index] = trimmed
    }

    /// Get the last N words from chunks before the given index (for cleanup context).
    func context(beforeIndex index: Int, maxWords: Int = 30) -> String {
        guard index > 0 else { return "" }
        let preceding = chunks[0..<index].joined(separator: " ")
        let words = preceding.split(separator: " ")
        return words.suffix(maxWords).joined(separator: " ")
    }

    func clear() {
        chunks.removeAll()
    }

    func copyAll() {
        let text = accumulatedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
