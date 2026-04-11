import Foundation
import NaturalLanguage

/// Local, on-device language detection for the main ⌘T translation flow.
/// Uses `NLLanguageRecognizer.dominantLanguage` — free, instant, no Claude call.
enum LanguageDetector {
    /// Minimum number of non-whitespace characters required before attempting detection.
    /// Shorter snippets produce unreliable results (e.g. "OK", "Hi").
    private static let minimumCharacterCount = 3

    /// Detects the dominant language of `text`. Returns `nil` when the text is too short
    /// or the recognizer is not confident enough (per Apple's own threshold).
    static func detect(text: String) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacterCount else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        return recognizer.dominantLanguage
    }

    /// Decides which `TargetLanguage` to translate *to*, given a detected source language
    /// and the user's primary/secondary preferences.
    ///
    /// Rules:
    /// - If detection failed (`nil`) → `primary`.
    /// - If detected language matches `primary` (by ISO language code) → `secondary`.
    /// - Otherwise → `primary`.
    static func resolveTarget(
        for detected: NLLanguage?,
        primary: TargetLanguage,
        secondary: TargetLanguage
    ) -> TargetLanguage {
        guard let detected else { return primary }

        let detectedCode = Locale.Language(identifier: detected.rawValue).languageCode?.identifier
        let primaryCode = primary.localeLanguage.languageCode?.identifier

        if let detectedCode, let primaryCode, detectedCode == primaryCode {
            return secondary
        }
        return primary
    }
}
