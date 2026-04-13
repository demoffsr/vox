import Foundation

final class ClaudeAPIService {
    enum APIError: Error, LocalizedError {
        case noAPIKey
        case invalidResponse(Int)
        case networkError(Error)
        case rateLimited
        case invalidAPIKey

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No API key configured. Add your key in Settings."
            case .invalidResponse(let code): return "API error (HTTP \(code))"
            case .networkError(let e): return "Network error: \(e.localizedDescription)"
            case .rateLimited: return "Too many requests, try again in a moment"
            case .invalidAPIKey: return "Invalid API key. Check your key in Settings."
            }
        }
    }

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
            "temperature": 0.2,
            "system": Constants.systemPrompt(targetLanguage: targetLanguage),
            "messages": [
                ["role": "user", "content": "<text>\n\(text)\n</text>"],
                ["role": "assistant", "content": "<translation>"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Strips markdown code fences and extracts the JSON object from LLM output.
    static func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove markdown code fences (```json ... ``` or ``` ... ```)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Find JSON object boundaries as a fallback
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }
        return cleaned
    }

    static func parseSSELine(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonString = String(line.dropFirst(6))
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    static func buildLookUpRequest(
        text: String,
        targetLanguage: TargetLanguage,
        apiKey: String,
        model: ClaudeModel = .sonnet
    ) throws -> URLRequest {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 1024,
            "stream": false,
            "temperature": 0.3,
            "system": Constants.lookUpPrompt(targetLanguage: targetLanguage),
            "messages": [
                ["role": "user", "content": "<text>\n\(text)\n</text>"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func lookUp(
        text: String,
        targetLanguage: TargetLanguage,
        apiKey: String
    ) async throws -> LookUpData {
        let request = try Self.buildLookUpRequest(
            text: text, targetLanguage: targetLanguage, apiKey: apiKey
        )

        // Try Sonnet first, then retry once. On persistent 429/529, fall back to Haiku.
        for attempt in 0..<2 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(1.5))
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse(0)
            }
            if http.statusCode == 429 || http.statusCode == 529 { continue }
            if http.statusCode == 401 { throw APIError.invalidAPIKey }
            if http.statusCode != 200 { throw APIError.invalidResponse(http.statusCode) }
            return try Self.parseLookUpResponse(data: data)
        }

        // Fallback to Haiku
        print("[LookUp] Sonnet unavailable, falling back to Haiku")
        let fallbackRequest = try Self.buildLookUpRequest(
            text: text, targetLanguage: targetLanguage, apiKey: apiKey,
            model: .haiku
        )
        let (data, response) = try await URLSession.shared.data(for: fallbackRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse(0)
        }
        if http.statusCode == 401 { throw APIError.invalidAPIKey }
        if http.statusCode == 429 { throw APIError.rateLimited }
        if http.statusCode != 200 { throw APIError.invalidResponse(http.statusCode) }
        return try Self.parseLookUpResponse(data: data)
    }

    private static func parseLookUpResponse(data: Data) throws -> LookUpData {

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let textContent = first["text"] as? String
        else {
            throw APIError.invalidResponse(200)
        }

        let cleanedJSON = Self.extractJSON(from: textContent)
        guard let jsonData = cleanedJSON.data(using: .utf8) else {
            throw APIError.invalidResponse(200)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let parsed = try decoder.decode(LookUpResponse.self, from: jsonData)
            let result = parsed.toLookUpData()
            if result.dictionary == nil && result.context == nil {
                print("[LookUp] Warning: parsed OK but dictionary & context are both nil. Raw JSON:\n\(cleanedJSON.prefix(500))")
            }
            return result
        } catch {
            print("[LookUp] Decode error: \(error)\nRaw JSON:\n\(cleanedJSON.prefix(500))")
            throw error
        }
    }

    func translate(
        text: String,
        model: ClaudeModel,
        apiKey: String,
        targetLanguage: TargetLanguage = .auto
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.buildRequest(text: text, model: model, apiKey: apiKey, targetLanguage: targetLanguage)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: APIError.invalidResponse(0))
                        return
                    }

                    switch httpResponse.statusCode {
                    case 200: break
                    case 401:
                        continuation.finish(throwing: APIError.invalidAPIKey)
                        return
                    case 429:
                        continuation.finish(throwing: APIError.rateLimited)
                        return
                    default:
                        continuation.finish(throwing: APIError.invalidResponse(httpResponse.statusCode))
                        return
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let text = Self.parseSSELine(line) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: APIError.networkError(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
