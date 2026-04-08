import SwiftUI

@Observable
@MainActor
final class TranslationStreamViewModel {
    private var refinedText: String = ""
    private var pendingChunks: [String] = []
    var isActive: Bool = false
    var isPolishing: Bool = false
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

    /// Replace the first `chunkCount` pending chunks with refined text.
    /// Chunks appended after the refine request started are preserved.
    func commitRefinedText(_ text: String, chunkCount: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if refinedText.isEmpty {
            refinedText = trimmed
        } else {
            refinedText += " " + trimmed
        }
        let removeCount = min(chunkCount, pendingChunks.count)
        pendingChunks.removeFirst(removeCount)
    }

    /// The last appended chunk (for Russian overlap trimming).
    var lastChunk: String {
        pendingChunks.last ?? refinedTail(maxWords: 8)
    }

    /// Get the last N words of refined text (for context in refine API call).
    func refinedTail(maxWords: Int = 30) -> String {
        guard !refinedText.isEmpty else { return "" }
        let words = refinedText.split(separator: " ")
        return words.suffix(maxWords).joined(separator: " ")
    }

    func replaceAll(_ text: String) {
        refinedText = text
        pendingChunks.removeAll()
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
