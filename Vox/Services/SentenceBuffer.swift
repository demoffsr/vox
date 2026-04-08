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

        if isFinal {
            checkBoundaryInChunk()
        } else {
            // Draft on volatile too — so user sees translation while speaking
            checkDraft()
        }
    }

    func reportSilence(durationMs: Int) {
        guard durationMs >= 600 else { return }
        guard confirmedWords.count >= 2 else { return }
        let text = confirmedWords.joined(separator: " ")
        guard !text.isEmpty else { return }
        onEvent?(.sentenceComplete(text: text))
        resetBuffer()
    }

    func reset() {
        confirmedWords = []
        volatileText = ""
        lastDraftWordCount = 0
    }

    // MARK: - Private

    /// Scan all confirmed words for sentence-ending punctuation.
    /// ASR often sends "them. One of" as a single chunk — the period is mid-chunk,
    /// not on the last word. We split at every boundary found.
    private func checkBoundaryInChunk() {
        // Scan for punctuation anywhere in the buffer
        if let splitIdx = confirmedWords.lastIndex(where: { word in
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
        }) {
            // Everything up to and including the punctuated word = complete sentence
            let sentenceWords = Array(confirmedWords.prefix(through: splitIdx))
            let remainingWords = Array(confirmedWords.suffix(from: confirmedWords.index(after: splitIdx)))

            let sentenceText = sentenceWords.joined(separator: " ")
            guard !sentenceText.isEmpty else { return }

            // Commit the sentence
            confirmedWords = remainingWords
            lastDraftWordCount = 0
            onEvent?(.sentenceComplete(text: sentenceText))

            // If remaining words exist, check for more boundaries (recursive)
            if !confirmedWords.isEmpty {
                checkBoundaryInChunk()
            }
            return
        }

        // No punctuation found — check overflow
        if confirmedWords.count >= 25 {
            let text = confirmedWords.joined(separator: " ")
            guard !text.isEmpty else { return }
            onEvent?(.sentenceComplete(text: text))
            resetBuffer()
            return
        }

        // No boundary — check draft
        checkDraft()
    }

    /// Trigger draft when enough new words accumulated (works for both final and volatile).
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
    }
}
