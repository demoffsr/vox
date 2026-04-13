import Foundation

// Copy this file to Prompts.swift and fill in your own prompt strings.
// Prompts.swift is gitignored — your prompts stay private.

enum Prompts {

    // MARK: - Main app translation prompt
    static func system(targetLanguage: TargetLanguage) -> String {
        // Your main translation system prompt.
        // Receives targetLanguage, should return translation instructions.
        fatalError("Copy Prompts.example.swift to Prompts.swift and add your prompts")
    }

    // MARK: - Live subtitle translation
    static func subtitleTranslation(targetLanguage: TargetLanguage) -> String {
        fatalError("Add your subtitle translation prompt")
    }

    // MARK: - Cinema/TV mode translation
    static func cinemaTranslation(targetLanguage: TargetLanguage) -> String {
        fatalError("Add your cinema translation prompt")
    }

    // MARK: - Dictionary / Look Up
    static func lookUp(targetLanguage: TargetLanguage) -> String {
        // Should return JSON schema instructions for dictionary entries.
        fatalError("Add your look-up prompt")
    }

    // MARK: - Safari Extension batch translation
    static func safariExtension(targetLanguage: TargetLanguage) -> String {
        fatalError("Add your Safari extension prompt")
    }

    // MARK: - ASR cleanup (correct misheard terms)
    static func asrCleanup(glossaryTerms: String, topic: String?, asrHints: String?) -> String {
        fatalError("Add your ASR cleanup prompt")
    }

    // MARK: - Topic detection
    static func topicDetection(cinemaMode: Bool) -> String {
        fatalError("Add your topic detection prompt")
    }

    // MARK: - History title generation
    static func historyTitle() -> String {
        fatalError("Add your history title prompt")
    }

    // MARK: - Glossary generation
    static func glossaryGeneration(targetLanguage: TargetLanguage) -> String {
        fatalError("Add your glossary generation prompt")
    }

    // MARK: - Combined topic + glossary detection
    static func topicWithGlossary(targetLanguage: TargetLanguage) -> String {
        fatalError("Add your topic+glossary prompt")
    }

    // MARK: - Polish translations
    static func polish(langName: String, topic: String?, glossary: Glossary?) -> String {
        fatalError("Add your polish prompt")
    }

    // MARK: - Summarize
    static func summarize(langName: String, topic: String?) -> String {
        fatalError("Add your summarize prompt")
    }

    // MARK: - Study notes
    static func studyNotes(langName: String, topic: String?) -> String {
        fatalError("Add your study notes prompt")
    }

    // MARK: - Cleanup (punctuation, capitalization)
    static func cleanup(langName: String) -> String {
        fatalError("Add your cleanup prompt")
    }
}
