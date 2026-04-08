import Foundation

enum Constants {
    static let maxClipboardLength = 5000
    static let defaultModel = ClaudeModel.haiku
    static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let keychainServiceName = "com.vox.apikey"
    static let appGroupID = "group.com.Vox.Vox"

    static func systemPrompt(targetLanguage: TargetLanguage) -> String {
        let langInstruction: String
        switch targetLanguage {
        case .auto:
            langInstruction = """
            - If the text is not in Russian, translate to Russian
            - If the text is in Russian, translate to English
            """
        case .english:
            langInstruction = "- Translate to English"
        case .russian:
            langInstruction = "- Translate to Russian"
        case .spanish:
            langInstruction = "- Translate to Spanish"
        case .french:
            langInstruction = "- Translate to French"
        case .german:
            langInstruction = "- Translate to German"
        case .chinese:
            langInstruction = "- Translate to Chinese (Simplified)"
        case .japanese:
            langInstruction = "- Translate to Japanese"
        }

        return """
        /* prompt redacted */ Translate the following text.

        Rules:
        \(langInstruction)
        - 
        - 
        - 
        - 
        - Return ONLY the translation, no explanations or preamble
        """
    }

    static func subtitleTranslationPrompt(targetLanguage: TargetLanguage) -> String {
        let lang: String
        switch targetLanguage {
        case .auto:     lang = "Russian"
        case .english:  lang = "English"
        case .russian:  lang = "Russian"
        case .spanish:  lang = "Spanish"
        case .french:   lang = "French"
        case .german:   lang = "German"
        case .chinese:  lang = "Simplified Chinese"
        case .japanese: lang = "Japanese"
        }

        return """
        /* prompt redacted */ // \(lang).
        
        
        
        
        
        """
    }

    static func cinemaTranslationPrompt(targetLanguage: TargetLanguage) -> String {
        let lang: String
        switch targetLanguage {
        case .auto:     lang = "Russian"
        case .english:  lang = "English"
        case .russian:  lang = "Russian"
        case .spanish:  lang = "Spanish"
        case .french:   lang = "French"
        case .german:   lang = "German"
        case .chinese:  lang = "Simplified Chinese"
        case .japanese: lang = "Japanese"
        }

        return """
        /* prompt redacted */ // \(lang).
        
         \(lang): colloquial forms, contractions, natural phrasing.
         \(lang) equivalents — never word-for-word.
        
        
        
        
        
        """
    }

    /// Punctuation characters that indicate a sentence end (Latin + CJK).
    static let sentenceEndCharacters: Set<Character> = [
        ".", "!", "?",
        "\u{3002}", // CJK period
        "\u{FF01}", // fullwidth !
        "\u{FF1F}", // fullwidth ?
    ]
}

enum ClaudeModel: String, CaseIterable, Identifiable {
    case haiku = "claude-haiku-4-5-20251001"
    case sonnet = "claude-sonnet-4-20250514"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku: return "Claude Haiku"
        case .sonnet: return "Claude Sonnet"
        }
    }
}

enum SubtitleLanguage: String, CaseIterable, Identifiable {
    case english = "en-US"
    case russian = "ru-RU"
    case spanish = "es-ES"
    case french = "fr-FR"
    case german = "de-DE"
    case chinese = "zh-CN"
    case japanese = "ja-JP"

    var id: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Russian"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        }
    }

    var flag: String {
        switch self {
        case .english: return "🇬🇧"
        case .russian: return "🇷🇺"
        case .spanish: return "🇪🇸"
        case .french: return "🇫🇷"
        case .german: return "🇩🇪"
        case .chinese: return "🇨🇳"
        case .japanese: return "🇯🇵"
        }
    }

    var languageCode: String {
        switch self {
        case .english:  return "en"
        case .russian:  return "ru"
        case .spanish:  return "es"
        case .french:   return "fr"
        case .german:   return "de"
        case .chinese:  return "zh"
        case .japanese: return "ja"
        }
    }

    var localeLanguage: Locale.Language {
        switch self {
        case .english:  return .init(identifier: "en")
        case .russian:  return .init(identifier: "ru")
        case .spanish:  return .init(identifier: "es")
        case .french:   return .init(identifier: "fr")
        case .german:   return .init(identifier: "de")
        case .chinese:  return .init(identifier: "zh-Hans")
        case .japanese: return .init(identifier: "ja")
        }
    }
}

enum TargetLanguage: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case english = "English"
    case russian = "Russian"
    case spanish = "Spanish"
    case french = "French"
    case german = "German"
    case chinese = "Chinese"
    case japanese = "Japanese"

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .auto: return "🌐"
        case .english: return "🇬🇧"
        case .russian: return "🇷🇺"
        case .spanish: return "🇪🇸"
        case .french: return "🇫🇷"
        case .german: return "🇩🇪"
        case .chinese: return "🇨🇳"
        case .japanese: return "🇯🇵"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .english: return "EN"
        case .russian: return "RU"
        case .spanish: return "ES"
        case .french: return "FR"
        case .german: return "DE"
        case .chinese: return "ZH"
        case .japanese: return "JA"
        }
    }

    var localeLanguage: Locale.Language {
        switch self {
        case .auto, .english: return .init(identifier: "en")
        case .russian:  return .init(identifier: "ru")
        case .spanish:  return .init(identifier: "es")
        case .french:   return .init(identifier: "fr")
        case .german:   return .init(identifier: "de")
        case .chinese:  return .init(identifier: "zh-Hans")
        case .japanese: return .init(identifier: "ja")
        }
    }
}

enum SubtitleDisplayMode: String, CaseIterable, Identifiable {
    case lecture = "Lecture"
    case cinema = "Cinema"
    var id: String { rawValue }
}
