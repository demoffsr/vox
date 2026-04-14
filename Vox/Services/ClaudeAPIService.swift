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

    /// Extracts a JSON object from LLM output. Cascade:
    /// 1) raw text already is a JSON object,
    /// 2) after stripping markdown fences,
    /// 3) first balanced {...} via brace-matching scanner that respects
    ///    string literals and \" / \\ escapes.
    /// Returns best-effort text; JSONDecoder surfaces a real error if all fail.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isJSONObject(trimmed) { return trimmed }

        let unfenced = Self.stripMarkdownFences(trimmed)
        if Self.isJSONObject(unfenced) { return unfenced }

        if let extracted = Self.firstBalancedJSONObject(in: unfenced) {
            return extracted
        }

        return unfenced
    }

    // Helpers are intentionally private: extractJSON is the single public
    // entry point; expanding surface "for symmetry" is not wanted.

    /// True only if the text parses as a JSON *object* (not array / string / null),
    /// since LookUpResponse expects a top-level object.
    private static func isJSONObject(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) != nil
    }

    private static func stripMarkdownFences(_ text: String) -> String {
        var cleaned = text
        guard cleaned.hasPrefix("```") else { return cleaned }
        if let firstNewline = cleaned.firstIndex(of: "\n") {
            cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scans for the first balanced {...}. Tracks inString, escaped state
    /// so braces inside string literals don't change depth and \" / \\
    /// are handled correctly.
    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let startIdx = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = startIdx
        while idx < text.endIndex {
            let c = text[idx]
            if escaped {
                escaped = false
            } else if inString {
                if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[startIdx...idx]) }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
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
