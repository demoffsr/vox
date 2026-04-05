import Foundation

enum Constants {
    static let defaultHotkey = "⌘⇧T"
    static let maxClipboardLength = 5000
    static let defaultModel = ClaudeModel.haiku
    static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let keychainServiceName = "com.vox.apikey"

    static let systemPrompt = """
    /* prompt redacted */ Translate the following text.

    Rules:
    - If the text is not in Russian, translate to Russian
    - If the text is in Russian, translate to English
    - 
    - 
    - 
    - 
    - Return ONLY the translation, no explanations or preamble
    """
}

enum ClaudeModel: String, CaseIterable, Identifiable {
    case haiku = "claude-haiku-4-5-20251001"
    case sonnet = "claude-sonnet-4-6-20260320"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku: return "Claude Haiku"
        case .sonnet: return "Claude Sonnet"
        }
    }
}
