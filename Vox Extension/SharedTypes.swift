// Shared types and services re-exported for Safari Extension target
// These mirror the main app's types to avoid target membership complexity

import Foundation
import Security

// MARK: - Constants

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
        case .english: langInstruction = "- Translate to English"
        case .russian: langInstruction = "- Translate to Russian"
        case .spanish: langInstruction = "- Translate to Spanish"
        case .french: langInstruction = "- Translate to French"
        case .german: langInstruction = "- Translate to German"
        case .chinese: langInstruction = "- Translate to Chinese (Simplified)"
        case .japanese: langInstruction = "- Translate to Japanese"
        }

        return """
        /* prompt redacted */

        Rules:
        \(langInstruction)
        - 
        - 
        - 
        - 
        - Translate naturally, preserving tone and idioms.

        Example input: ["Home", "About us", "Contact"]
        Example output: ["Главная", "О нас", "Контакты"]
        """
    }
}

// MARK: - ClaudeModel

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

// MARK: - TargetLanguage

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
}

// MARK: - KeychainHelper

struct KeychainHelper {
    let service: String
    let accessGroup: String?

    init(service: String = Constants.keychainServiceName, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - ClaudeAPIService

final class ClaudeAPIService {
    static func buildRequest(text: String, model: ClaudeModel, apiKey: String, targetLanguage: TargetLanguage = .auto) throws -> URLRequest {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 4096,
            "stream": true,
            "system": Constants.systemPrompt(targetLanguage: targetLanguage),
            "messages": [["role": "user", "content": text]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
