import Foundation

/// Translates subtitle text via Claude API with streaming support.
final class SubtitleTranslator {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func translateStreaming(
        text: String,
        language: TargetLanguage,
        model: ClaudeModel = .haiku,
        previousTurn: (english: String, russian: String)? = nil,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        var messages: [[String: String]] = []
        if let prev = previousTurn {
            messages.append(["role": "user", "content": prev.english])
            messages.append(["role": "assistant", "content": prev.russian])
        }
        messages.append(["role": "user", "content": text])

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 200,
            "stream": true,
            "system": Constants.subtitleTranslationPrompt(targetLanguage: language),
            "messages": messages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIService.APIError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            switch httpResponse.statusCode {
            case 401: throw ClaudeAPIService.APIError.invalidAPIKey
            case 429: throw ClaudeAPIService.APIError.rateLimited
            default:  throw ClaudeAPIService.APIError.invalidResponse(httpResponse.statusCode)
            }
        }

        var fullText = ""

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]",
                  let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               let token = delta["text"] as? String {
                fullText += token
                await MainActor.run { onToken(token) }
            }
        }

        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Post-process a batch of translated text: fix punctuation, capitalization, sentence breaks.
    /// Uses Haiku for speed. Returns cleaned text, or nil on failure.
    func cleanup(text: String, context: String, language: TargetLanguage) async -> String? {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 5

        let langName: String
        switch language {
        case .auto, .russian: langName = "Russian"
        case .english: langName = "English"
        case .spanish: langName = "Spanish"
        case .french: langName = "French"
        case .german: langName = "German"
        case .chinese: langName = "Simplified Chinese"
        case .japanese: langName = "Japanese"
        }

        let system = """
        /* prompt redacted */ \(langName) 
        Fix the new text ONLY:
        - Add proper punctuation: commas, periods, question marks where sentences end
        - 
        - If the new text continues mid-sentence from context, do NOT capitalize the first word
        - Split run-on text into proper sentences
        - Keep meaning exactly the same — do not add, remove, or rephrase words
        - 
        """

        var userContent = ""
        if !context.isEmpty {
            userContent += "Context (previous text): \(context)\n\n"
        }
        userContent += "New text to clean up: \(text)"

        let body: [String: Any] = [
            "model": ClaudeModel.haiku.rawValue,
            "max_tokens": 400,
            "stream": false,
            "system": system,
            "messages": [["role": "user", "content": userContent]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let result = firstBlock["text"] as? String else {
                return nil
            }

            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            print("[Cleanup] FAILED: \(error)")
            return nil
        }
    }
}
