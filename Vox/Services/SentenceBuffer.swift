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
    private var bufferStartTime: TimeInterval = 0  // when first word arrived
    private var draftDebounce: Task<Void, Never>?

    /// All confirmed words + full volatile (for display/reference).
    var fullText: String {
        var all = confirmedWords.joined(separator: " ")
        if !volatileText.isEmpty {
            if !all.isEmpty { all += " " }
            all += volatileText
        }
        return all
    }

    /// Text safe for translation: confirmed + volatile minus last word
    /// (last volatile word may be a truncated fragment like "quant" for "quantum").
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

    // MARK: - Input

    /// Total words currently in buffer (confirmed + volatile).
    private var totalWordCount: Int {
        confirmedWords.count + volatileText.split(separator: " ").count
    }

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

        if isFinal {
            checkBoundaryInChunk()
        } else {
            // Draft on volatile too — debounced to avoid spamming API
            scheduleDraft()
        }
    }

    func reportSilence(durationMs: Int) {
        guard durationMs >= 600 else { return }
        let total = totalWordCount
        guard total >= 2 else { return }
        let text = allText
        guard !text.isEmpty else { return }
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

    // MARK: - Private

    /// All words joined (confirmed + volatile minus last volatile word for safety).
    private var allText: String {
        safeText
    }

    /// Scan all confirmed words for sentence-ending punctuation.
    /// ASR often sends "them. One of" as a single chunk — the period is mid-chunk,
    /// not on the last word. We split at every boundary found.
    private func checkBoundaryInChunk() {
        // Scan for punctuation anywhere in confirmed words
        if let splitIdx = confirmedWords.lastIndex(where: { word in
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
        }) {
            let sentenceWords = Array(confirmedWords.prefix(through: splitIdx))
            let remainingWords = Array(confirmedWords.suffix(from: confirmedWords.index(after: splitIdx)))

            let sentenceText = sentenceWords.joined(separator: " ")
            guard !sentenceText.isEmpty else { return }

            confirmedWords = remainingWords
            lastDraftWordCount = 0
            bufferStartTime = confirmedWords.isEmpty ? 0 : Date().timeIntervalSince1970
            draftDebounce?.cancel()
            onEvent?(.sentenceComplete(text: sentenceText))

            if !confirmedWords.isEmpty {
                checkBoundaryInChunk()
            }
            return
        }

        // Total word overflow (confirmed + volatile) — catches long sentences
        // where ASR doesn't add punctuation
        if totalWordCount >= 20 {
            let text = allText
            guard !text.isEmpty else { return }
            draftDebounce?.cancel()
            onEvent?(.sentenceComplete(text: text))
            resetBuffer()
            return
        }

        // Time-based fallback: if buffer has been filling for > 10 seconds,
        // force a sentence boundary. Prevents infinite accumulation when
        // speaker talks continuously without pauses.
        if bufferStartTime > 0 && totalWordCount >= 5 {
            let elapsed = Date().timeIntervalSince1970 - bufferStartTime
            if elapsed >= 10.0 {
                let text = allText
                guard !text.isEmpty else { return }
                draftDebounce?.cancel()
                onEvent?(.sentenceComplete(text: text))
                resetBuffer()
                return
            }
        }

        // No boundary — check draft
        checkDraft()
    }

    /// Debounce draft: wait 600ms after last word before sending.
    /// Avoids spamming cancelled API requests on every volatile update.
    private func scheduleDraft() {
        draftDebounce?.cancel()
        draftDebounce = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            self.checkDraft()
        }
    }

    /// Trigger draft when enough new words accumulated.
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
