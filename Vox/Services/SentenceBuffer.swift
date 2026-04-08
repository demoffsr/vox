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
            checkBoundary()
        } else {
            // Draft on volatile too — so user sees translation while speaking
            checkDraft()
        }
    }

    func reportSilence(durationMs: Int) {
        guard durationMs >= 700 else { return }
        guard confirmedWords.count >= 2 else { return }
        let text = safeText
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

    private func checkBoundary() {
        // 1. Punctuation: last confirmed word ends with . ? !
        if let lastWord = confirmedWords.last {
            let trimmed = lastWord.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") {
                let text = safeText
                guard !text.isEmpty else { return }
                onEvent?(.sentenceComplete(text: text))
                resetBuffer()
                return
            }
        }

        // 2. Buffer overflow: >= 25 confirmed words
        if confirmedWords.count >= 25 {
            let text = safeText
            guard !text.isEmpty else { return }
            onEvent?(.sentenceComplete(text: text))
            resetBuffer()
            return
        }

        // 3. Also check draft on final words
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
