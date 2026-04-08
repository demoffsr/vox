// Vox/Services/SentenceBuffer.swift
import Foundation

/// Accumulates ASR text, detects sentence boundaries, emits draft/final events.
///
/// Handles both cumulative ASR (SpeechTranscriber — text grows session-wide)
/// and resetting ASR (DictationTranscriber — text resets after isFinal).
/// Uses a word-count offset to track what's been committed.
@MainActor
final class SentenceBuffer {
    enum Event {
        case draftReady(text: String)
        case sentenceComplete(text: String)
    }

    var onEvent: ((Event) -> Void)?

    // Full text from ASR — replaced (not appended) on every callback
    private var fullText: String = ""
    private var isLatestFinal: Bool = false

    // Offset: how many words from fullText have been committed
    private var consumedWordCount: Int = 0

    // Draft tracking
    private var lastDraftUnconsumedCount: Int = 0
    private var draftDebounce: Task<Void, Never>?
    private var timeOverflowTimer: Task<Void, Never>?

    // MARK: - Derived State

    private var allWords: [String] {
        fullText.split(separator: " ").map(String.init)
    }

    /// Words not yet committed via sentenceComplete.
    private var unconsumedWords: [String] {
        let words = allWords
        // If ASR reset (DictationTranscriber), word count drops below consumed
        if words.count < consumedWordCount {
            consumedWordCount = 0
        }
        return Array(words.dropFirst(consumedWordCount))
    }

    /// Unconsumed text safe for translation (drops last word if volatile — may be truncated).
    private var safeText: String {
        var words = unconsumedWords
        if !isLatestFinal && !words.isEmpty {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    // MARK: - Input

    func accumulateWords(_ text: String, isFinal: Bool) {
        fullText = text  // REPLACE — ASR gives cumulative text
        isLatestFinal = isFinal

        let count = unconsumedWords.count

        // Start time overflow timer when first unconsumed words appear
        if timeOverflowTimer == nil && count > 0 {
            startTimeOverflow()
        }

        if isFinal {
            if checkPunctuation() { return }
            if checkOverflow() { return }
            checkDraft()
        } else {
            scheduleDraft()
        }
    }

    func reportSilence(durationMs: Int) {
        guard durationMs >= 600 else { return }
        guard unconsumedWords.count >= 2 else { return }
        let text = safeText
        guard !text.isEmpty else { return }
        commitSentence(text)
    }

    func reset() {
        fullText = ""
        consumedWordCount = 0
        lastDraftUnconsumedCount = 0
        isLatestFinal = false
        draftDebounce?.cancel()
        draftDebounce = nil
        timeOverflowTimer?.cancel()
        timeOverflowTimer = nil
    }

    // MARK: - Boundary Detection

    /// Scan unconsumed words for sentence-ending punctuation (.?!).
    private func checkPunctuation() -> Bool {
        let words = unconsumedWords
        guard let splitIdx = words.lastIndex(where: { word in
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
        }) else { return false }

        let sentenceWords = Array(words.prefix(through: splitIdx))
        let sentenceText = sentenceWords.joined(separator: " ")
        guard !sentenceText.isEmpty else { return false }

        commitSentence(sentenceText)

        // Check for more punctuation in remaining unconsumed
        if !unconsumedWords.isEmpty {
            _ = checkPunctuation()
        }
        return true
    }

    /// Word count overflow — only on isFinal.
    private func checkOverflow() -> Bool {
        guard unconsumedWords.count >= 18 else { return false }
        let text = safeText
        guard !text.isEmpty else { return false }
        commitSentence(text)
        return true
    }

    // MARK: - Time Overflow

    private func startTimeOverflow() {
        timeOverflowTimer?.cancel()
        timeOverflowTimer = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            guard self.unconsumedWords.count >= 4 else { return }
            let text = self.safeText
            guard !text.isEmpty else { return }
            self.commitSentence(text)
        }
    }

    // MARK: - Draft

    private func scheduleDraft() {
        draftDebounce?.cancel()
        draftDebounce = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            self.checkDraft()
        }
    }

    private func checkDraft() {
        let count = unconsumedWords.count
        guard count >= 3 else { return }
        guard count - lastDraftUnconsumedCount >= 3 else { return }

        let text = safeText
        guard !text.isEmpty else { return }
        onEvent?(.draftReady(text: text))
        lastDraftUnconsumedCount = count
    }

    // MARK: - Commit

    private func commitSentence(_ text: String) {
        let committedWords = text.split(separator: " ").count
        consumedWordCount += committedWords
        lastDraftUnconsumedCount = 0

        draftDebounce?.cancel()
        draftDebounce = nil
        timeOverflowTimer?.cancel()
        timeOverflowTimer = nil

        onEvent?(.sentenceComplete(text: text))

        // Restart timer if unconsumed text remains
        if unconsumedWords.count > 0 {
            startTimeOverflow()
        }
    }
}
