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
    private var bufferStartTime: TimeInterval = 0
    private var draftDebounce: Task<Void, Never>?

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

        // Track when buffer started filling
        if bufferStartTime == 0 && totalWordCount > 0 {
            bufferStartTime = Date().timeIntervalSince1970
        }

        // Punctuation check only on final words (volatile may be incomplete)
        if isFinal {
            if checkPunctuation() { return }
        }

        // Overflow and time checks run on EVERY update (volatile too)
        if checkOverflow() { return }

        // Draft — debounced on volatile, immediate on final
        if isFinal {
            checkDraft()
        } else {
            scheduleDraft()
        }
    }

    func reportSilence(durationMs: Int) {
        guard durationMs >= 600 else { return }
        guard totalWordCount >= 2 else { return }
        let text = safeText
        guard !text.isEmpty else { return }
        draftDebounce?.cancel()
        onEvent?(.sentenceComplete(text: text))
        resetBuffer()
    }

    func reset() {
        confirmedWords = []
        volatileText = ""
        lastDraftWordCount = 0
        bufferStartTime = 0
        draftDebounce?.cancel()
        draftDebounce = nil
    }

    // MARK: - Boundary Detection

    /// Scan confirmed words for sentence-ending punctuation (.?!).
    /// Returns true if a boundary was found and handled.
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
        bufferStartTime = confirmedWords.isEmpty ? 0 : Date().timeIntervalSince1970
        draftDebounce?.cancel()
        onEvent?(.sentenceComplete(text: sentenceText))

        // Recurse if remaining words also contain punctuation
        if !confirmedWords.isEmpty {
            _ = checkPunctuation()
        }
        return true
    }

    /// Check word count and time-based overflow.
    /// Returns true if a boundary was triggered.
    private func checkOverflow() -> Bool {
        let total = totalWordCount

        // Word overflow: >= 18 total words → force sentence boundary
        if total >= 18 {
            let text = safeText
            guard !text.isEmpty else { return false }
            draftDebounce?.cancel()
            onEvent?(.sentenceComplete(text: text))
            resetBuffer()
            return true
        }

        // Time overflow: > 8 seconds of accumulation with >= 5 words
        if bufferStartTime > 0 && total >= 5 {
            let elapsed = Date().timeIntervalSince1970 - bufferStartTime
            if elapsed >= 8.0 {
                let text = safeText
                guard !text.isEmpty else { return false }
                draftDebounce?.cancel()
                onEvent?(.sentenceComplete(text: text))
                resetBuffer()
                return true
            }
        }

        return false
    }

    // MARK: - Draft

    /// Debounce draft: wait 500ms after last volatile word before sending.
    private func scheduleDraft() {
        draftDebounce?.cancel()
        draftDebounce = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            self.checkDraft()
        }
    }

    /// Emit draft if enough new words accumulated.
    private func checkDraft() {
        let total = totalWordCount
        guard total >= 3 else { return }
        guard total - lastDraftWordCount >= 3 else { return }

        let text = safeText
        guard !text.isEmpty else { return }
        onEvent?(.draftReady(text: text))
        lastDraftWordCount = total
    }

    private func resetBuffer() {
        confirmedWords = []
        volatileText = ""
        lastDraftWordCount = 0
        bufferStartTime = 0
        draftDebounce?.cancel()
        draftDebounce = nil
    }
}
