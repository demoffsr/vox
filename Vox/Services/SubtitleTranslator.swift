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
}
