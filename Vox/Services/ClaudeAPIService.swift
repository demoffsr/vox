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
            "system": Constants.systemPrompt(targetLanguage: targetLanguage),
            "messages": [
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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
