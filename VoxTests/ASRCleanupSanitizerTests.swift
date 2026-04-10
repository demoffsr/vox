import Testing
@testable import Vox

struct ASRCleanupSanitizerTests {
    @Test func acceptsNormalSubstitution() {
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: "homeland fought with soups",
            cleaned: "Homelander fought with Supes"
        )
        #expect(result == .accept("Homelander fought with Supes"))
    }

    @Test func acceptsUnchangedText() {
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: "she walked away",
            cleaned: "she walked away"
        )
        #expect(result == .accept("she walked away"))
    }

    @Test func rejectsEmptyOutput() {
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: "hello there",
            cleaned: ""
        )
        #expect(result == .reject(reason: "empty"))
    }

    @Test func rejectsWhitespaceOnlyOutput() {
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: "hello there",
            cleaned: "   \n  "
        )
        #expect(result == .reject(reason: "empty"))
    }

    @Test func rejectsLengthHallucination() {
        // 2-char input → 48-char output is far more than 1.5x
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: "hi",
            cleaned: "hi everyone welcome to the show tonight we have"
        )
        guard case .reject(let reason) = result else {
            Issue.record("expected reject, got \(result)")
            return
        }
        #expect(reason.contains("length"))
    }

    @Test func acceptsLengthWithinThreshold() {
        // "homeland" (8) → "Homelander" (10) = 1.25x, well within 1.5x
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: "homeland",
            cleaned: "Homelander"
        )
        #expect(result == .accept("Homelander"))
    }

    @Test func rejectsNonASCIILeakTranslation() {
        // Haiku slipped into Russian — non-ASCII in cleaned not present in original
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: "hello there",
            cleaned: "привет"
        )
        guard case .reject(let reason) = result else {
            Issue.record("expected reject, got \(result)")
            return
        }
        #expect(reason.contains("non-ASCII"))
    }

    @Test func acceptsNonASCIIPresentInBothOriginalAndCleaned() {
        // Smart quotes in both → same non-ASCII chars → accept
        let original = "she said \u{201C}hello\u{201D}"
        let cleaned = "she said \u{201C}hello\u{201D}"
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: original,
            cleaned: cleaned
        )
        #expect(result == .accept(cleaned))
    }

    @Test func rejectsNewNonASCIIEvenIfOriginalHadSome() {
        // Original has one smart quote; cleaned adds Cyrillic — still a leak
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: "she said \u{201C}hello\u{201D}",
            cleaned: "она сказала \u{201C}hello\u{201D}"
        )
        guard case .reject(let reason) = result else {
            Issue.record("expected reject, got \(result)")
            return
        }
        #expect(reason.contains("non-ASCII"))
    }

    @Test func trimsWhitespaceOnAccept() {
        let result = SubtitleTranslator.sanitizeCleanupResult(
            original: "hello",
            cleaned: "  hello  "
        )
        #expect(result == .accept("hello"))
    }
}
