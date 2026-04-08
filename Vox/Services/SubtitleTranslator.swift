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
        topic: String? = nil,
        cinemaMode: Bool = false,
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

        var system = cinemaMode
            ? Constants.cinemaTranslationPrompt(targetLanguage: language)
            : Constants.subtitleTranslationPrompt(targetLanguage: language)
        if let topic {
            system += "\nShow/movie context: \(topic)"
        }

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 200,
            "stream": true,
            "system": system,
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

        var result = fullText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip model reasoning that leaked into output (e.g. "Wait, I need to...")
        // If translating to a non-English language, drop lines that are clearly English meta-text.
        if language != .english {
            let lines = result.components(separatedBy: "\n")
            let filtered = lines.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Drop empty lines and lines that look like English reasoning
                if trimmed.isEmpty { return false }
                let looksEnglish = trimmed.hasPrefix("Wait") || trimmed.hasPrefix("Note:") ||
                    trimmed.hasPrefix("I need") || trimmed.hasPrefix("The correct") ||
                    trimmed.hasPrefix("Let me")
                return !looksEnglish
            }
            result = filtered.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    /// Detect the general topic of the video from accumulated English text.
    /// Single non-streaming Haiku request, returns a short topic string (3-5 words).
    func detectTopic(from text: String, cinemaMode: Bool = false) async -> String? {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = cinemaMode ? 10 : 5

        let model = cinemaMode ? ClaudeModel.sonnet : ClaudeModel.haiku
        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": cinemaMode ? 50 : 30,
            "stream": false,
            "system": cinemaMode
                ? "/* prompt redacted */ Include the name (if recognizable), genre, and setting. Answer in 5-10 words. No punctuation."
                : "/* prompt redacted */ No punctuation.",
            "messages": [["role": "user", "content": text]]
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

            let topic = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return topic.isEmpty ? nil : topic
        } catch {
            print("[Topic] FAILED: \(error)")
            return nil
        }
    }

    /// Polish the full translated text: fix obvious translation errors using Sonnet + topic context.
    /// Non-streaming, user-triggered one-shot. Returns corrected text, or nil on failure.
    func polish(text: String, topic: String?, language: TargetLanguage) async -> String? {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

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

        var system = """
        /* prompt redacted */ \(langName) subtitles.
        
        
        
        """
        if let topic {
            system += "\nVideo topic: \(topic)"
        }

        let body: [String: Any] = [
            "model": ClaudeModel.sonnet.rawValue,
            "max_tokens": 4096,
            "stream": false,
            "system": system,
            "messages": [["role": "user", "content": text]]
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

            let polished = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return polished.isEmpty ? nil : polished
        } catch {
            print("[Polish] FAILED: \(error)")
            return nil
        }
    }

    /// Summarize the translated text: extract key points as bullet-point summary.
    /// Non-streaming Sonnet request. Returns summary text, or nil on failure.
    func summarize(text: String, topic: String?, language: TargetLanguage) async -> String? {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

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

        var system = """
        /* prompt redacted */ \(langName) subtitles as a concise bullet-point summary.
        
        
        
        Output in \(langName).  (•) for each point.
        
        """
        if let topic {
            system += "\nVideo topic: \(topic)"
        }

        let body: [String: Any] = [
            "model": ClaudeModel.sonnet.rawValue,
            "max_tokens": 4096,
            "stream": false,
            "system": system,
            "messages": [["role": "user", "content": text]]
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

            let summary = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? nil : summary
        } catch {
            print("[Summarize] FAILED: \(error)")
            return nil
        }
    }

    /// Format translated text as structured study/lecture notes.
    /// Non-streaming Sonnet request. Returns formatted notes, or nil on failure.
    func studyNotes(text: String, topic: String?, language: TargetLanguage) async -> String? {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

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

        var system = """
         \(langName) /* prompt redacted */
        Include:
        - 
        - 
        - 
        - 
        - 
         Output in \(langName).
        
        """
        if let topic {
            system += "\nVideo topic: \(topic)"
        }

        let body: [String: Any] = [
            "model": ClaudeModel.sonnet.rawValue,
            "max_tokens": 4096,
            "stream": false,
            "system": system,
            "messages": [["role": "user", "content": text]]
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

            let notes = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return notes.isEmpty ? nil : notes
        } catch {
            print("[StudyNotes] FAILED: \(error)")
            return nil
        }
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
        - 
        -  — do NOT add closing punctuation
        - 
        - 
        - 
        - , do not guess missing words
        - 
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
