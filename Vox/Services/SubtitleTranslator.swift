import Foundation

final class SubtitleTranslator {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func translate(_ text: String) async throws -> String {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": ClaudeModel.haiku.rawValue,
            "max_tokens": 256,
            "stream": false,
            "system": "Translate English to Russian. Output ONLY the translation, nothing else. Keep it natural and concise.",
            "messages": [
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIService.APIError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            switch httpResponse.statusCode {
            case 401:
                throw ClaudeAPIService.APIError.invalidAPIKey
            case 429:
                throw ClaudeAPIService.APIError.rateLimited
            default:
                throw ClaudeAPIService.APIError.invalidResponse(httpResponse.statusCode)
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let translated = first["text"] as? String else {
            throw ClaudeAPIService.APIError.invalidResponse(200)
        }

        return translated.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
