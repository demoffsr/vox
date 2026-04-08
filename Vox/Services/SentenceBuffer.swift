// Vox/Services/SentenceBuffer.swift
import Foundation

@MainActor
final class SentenceBuffer {
    enum Event {
        case draftReady(text: String)
        case sentenceComplete(text: String)
    }

    var onEvent: ((Event) -> Void)?

    private var confirmedWords: [String] = []
    private var volatileText: String = ""
    private var lastDraftWordCount: Int = 0
    private var draftDebounce: Task<Void, Never>?
    private var timeOverflowTimer: Task<Void, Never>?

    /// Text safe for translation: confirmed + volatile minus last word.
    var safeText: String {
        var all = confirmedWords.joined(separator: " ")
        if !volatileText.isEmpty {
            var volatileWords = volatileText.split(separator: " ").map(String.init)
            if !volatileWords.isEmpty { volatileWords.removeLast() }
            let safe = volatileWords.joined(separator: " ")
            if !safe.isEmpty {
                if !all.isEmpty { all += " " }
                all += safe
            }
        }
        return all
    }

    /// Total words currently in buffer (confirmed + volatile).
    private var totalWordCount: Int {
        confirmedWords.count + volatileText.split(separator: " ").count
    }

    // MARK: - Input

    func accumulateWords(_ text: String, isFinal: Bool) {
        if isFinal {
            let words = text.split(separator: " ").map(String.init)
            confirmedWords += words
            volatileText = ""
        } else {
            volatileText = text
        }

        // Start time overflow timer on first word
        if timeOverflowTimer == nil && totalWordCount > 0 {
            startTimeOverflow()
        }

        if isFinal {
            // Punctuation + overflow only on confirmed words
            if checkPunctuation() { return }
            if checkOverflow() { return }
            checkDraft()
        } else {
            // Volatile: only debounced drafts (no overflow — volatile is non-incremental)
            scheduleDraft()
        }
    }

    func reportSilence(durationMs: Int) {
        guard durationMs >= 600 else { return }
        guard totalWordCount >= 2 else { return }
        let text = safeText
        guard !text.isEmpty else { return }
        commitSentence(text)
    }

    func reset() {
        confirmedWords = []
        volatileText = ""
        lastDraftWordCount = 0
        draftDebounce?.cancel()
        draftDebounce = nil
        timeOverflowTimer?.cancel()
        timeOverflowTimer = nil
    }

    // MARK: - Boundary Detection

    /// Scan confirmed words for sentence-ending punctuation (.?!).
    private func checkPunctuation() -> Bool {
        guard let splitIdx = confirmedWords.lastIndex(where: { word in
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
        }) else { return false }

        let sentenceWords = Array(confirmedWords.prefix(through: splitIdx))
        let remainingWords = Array(confirmedWords.suffix(from: confirmedWords.index(after: splitIdx)))
        let sentenceText = sentenceWords.joined(separator: " ")
        guard !sentenceText.isEmpty else { return false }

        confirmedWords = remainingWords
        lastDraftWordCount = 0
        restartTimeOverflow()
        draftDebounce?.cancel()
        onEvent?(.sentenceComplete(text: sentenceText))

        if !confirmedWords.isEmpty {
            _ = checkPunctuation()
        }
        return true
    }

    /// Word count overflow — only called on isFinal.
    private func checkOverflow() -> Bool {
        // Use confirmed words count (reliable) + volatile
        let total = totalWordCount
        guard total >= 18 else { return false }

        let text = safeText
        guard !text.isEmpty else { return false }
        commitSentence(text)
        return true
    }

    // MARK: - Time Overflow

    /// Start a timer: if buffer has been filling for 8 seconds, force sentenceComplete.
    private func startTimeOverflow() {
        timeOverflowTimer?.cancel()
        timeOverflowTimer = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            guard self.totalWordCount >= 4 else { return }
            let text = self.safeText
            guard !text.isEmpty else { return }
            self.commitSentence(text)
        }
    }

    private func restartTimeOverflow() {
        timeOverflowTimer?.cancel()
        timeOverflowTimer = nil
        if totalWordCount > 0 {
            startTimeOverflow()
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
        let total = totalWordCount
        guard total >= 3 else { return }
        guard total - lastDraftWordCount >= 3 else { return }

        let text = safeText
        guard !text.isEmpty else { return }
        onEvent?(.draftReady(text: text))
        lastDraftWordCount = total
    }

    // MARK: - Commit

    private func commitSentence(_ text: String) {
        draftDebounce?.cancel()
        draftDebounce = nil
        timeOverflowTimer?.cancel()
        timeOverflowTimer = nil
        confirmedWords = []
        volatileText = ""
        lastDraftWordCount = 0
        onEvent?(.sentenceComplete(text: text))
    }
}
