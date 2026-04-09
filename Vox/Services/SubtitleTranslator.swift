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
        previousTurns: [(original: String, translated: String)] = [],
        topic: String? = nil,
        glossary: Glossary? = nil,
        cinemaMode: Bool = false,
        temperature: Double = 0.2,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let result = try await executeTranslationRequest(
            text: text, language: language, model: model,
            previousTurns: previousTurns, topic: topic,
            glossary: glossary,
            cinemaMode: cinemaMode, temperature: temperature,
            onToken: onToken
        )

        if let rejection = validateTranslation(result, original: text, language: language) {
            print("[QualityFilter] REJECTED: \(rejection) — retrying with temp +0.1")

            let retryResult = try await executeTranslationRequest(
                text: text, language: language, model: model,
                previousTurns: previousTurns, topic: topic,
                glossary: glossary,
                cinemaMode: cinemaMode, temperature: min(temperature + 0.1, 1.0),
                onToken: { _ in }
            )

            if let retryRejection = validateTranslation(retryResult, original: text, language: language) {
                print("[QualityFilter] RETRY ALSO REJECTED: \(retryRejection) — returning empty")
                return ""
            }

            print("[QualityFilter] Retry passed")
            return retryResult
        }

        return result
    }

    // MARK: - Quality Filter

    /// Checks if a translation result passes quality heuristics.
    /// Returns a rejection reason string if rejected, or nil if acceptable.
    private func validateTranslation(_ translation: String, original: String, language: TargetLanguage) -> String? {
        // 1. Empty or whitespace/punctuation only
        let stripped = translation.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if stripped.isEmpty {
            return "empty/punctuation-only"
        }

        // 2. Translation equals original (not translated)
        // Exception: short interjections/onomatopoeia are the same across languages
        if translation.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ==
           original.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            let words = original.split(separator: " ")
            let isShortInterjection = words.count <= 4
                && original.unicodeScalars.allSatisfy { CharacterSet.letters.union(.whitespaces).union(.punctuationCharacters).contains($0) }
            if !isShortInterjection {
                return "identical to original"
            }
        }

        // 3. Leaked reasoning phrases
        let lower = translation.lowercased()
        let leakedPhrases = [
            "i'll translate", "i will translate",
            "here's the translation", "here is the translation",
            "the translation is", "translation:",
            "i'll provide", "let me translate"
        ]
        for phrase in leakedPhrases {
            if lower.contains(phrase) {
                return "leaked reasoning: \(phrase)"
            }
        }

        // 4. Length > 3x original (hallucination)
        if translation.count > original.count * 3 {
            return "hallucination (length \(translation.count) > 3x original \(original.count))"
        }

        // 5. >60% same words as original (not translated) — only for non-English targets
        if language != .english {
            let originalWords = Set(original.lowercased().split(separator: " ").map(String.init))
            let translationWords = translation.lowercased().split(separator: " ").map(String.init)
            if !translationWords.isEmpty {
                let matchCount = translationWords.filter { originalWords.contains($0) }.count
                let matchRatio = Double(matchCount) / Double(translationWords.count)
                if matchRatio > 0.6 {
                    return "untranslated (\(Int(matchRatio * 100))% same words)"
                }
            }
        }

        return nil
    }

    // MARK: - Translation Request

    private func executeTranslationRequest(
        text: String,
        language: TargetLanguage,
        model: ClaudeModel,
        previousTurns: [(original: String, translated: String)],
        topic: String?,
        glossary: Glossary? = nil,
        cinemaMode: Bool,
        temperature: Double,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        var messages: [[String: String]] = []
        for turn in previousTurns {
            messages.append(["role": "user", "content": turn.original])
            messages.append(["role": "assistant", "content": turn.translated])
        }
        messages.append(["role": "user", "content": text])

        var system = cinemaMode
            ? Constants.cinemaTranslationPrompt(targetLanguage: language)
            : Constants.subtitleTranslationPrompt(targetLanguage: language)
        if let topic {
            system += "\nShow/movie context: \(topic)"
        }
        if let glossary {
            system += glossary.promptFragment
        }
        if let asrHints = glossary?.asrPromptFragment {
            system += asrHints
        }

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 200,
            "stream": true,
            "temperature": temperature,
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
            "temperature": 0.3,
            "system": cinemaMode
                ? "/* prompt redacted */   Answer in 5-10 words. No punctuation."
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
            if topic.isEmpty { return nil }
            // Reject refusals — model should always guess, but filter just in case
            let lower = topic.lowercased()
            if lower.contains("cannot") || lower.contains("can't") || lower.contains("not enough") || lower.contains("unable to") {
                return nil
            }
            return topic
        } catch {
            print("[Topic] FAILED: \(error)")
            return nil
        }
    }

    // MARK: - Glossary Generation

    /// Generate a translation glossary for a known show/movie.
    /// Single non-streaming Sonnet request.
    func generateGlossary(
        showName: String,
        targetLanguage: TargetLanguage,
        isUserProvided: Bool
    ) async -> Glossary? {
        let langName = targetLanguage.displayName

        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": ClaudeModel.sonnet.rawValue,
            "max_tokens": 500,
            "stream": false,
            "temperature": 0.3,
            "system": """
            /* prompt redacted */
             \(langName).

            Rules:
            - 
            -  → \(langName) equivalent (one per line)
            - , key idioms/expletives used in the show
            - For proper nouns (character names, organization names, place names):  \(langName) name from the localized version of the show. If no official \(langName) localization exists, keep the original English spelling — 
            - For slang and in-universe terms:  \(langName) equivalents that match the show's tone
            - If you're not confident about a specific translation, mark it with [?]
            -  with common speech recognition mishearings
              Format: misheard → correct (e.g. "soups" → "supes")

            
            """,
            "messages": [["role": "user", "content": "Show: \(showName)"]]
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

            return Glossary.parse(raw: result, showName: showName, isUserProvided: isUserProvided)
        } catch {
            print("[Glossary] FAILED: \(error)")
            return nil
        }
    }

    /// Detect topic AND generate glossary in a single Sonnet call (for auto-detect in cinema mode).
    func detectTopicWithGlossary(
        from text: String,
        targetLanguage: TargetLanguage
    ) async -> (topic: String, glossary: Glossary)? {
        let langName = targetLanguage.displayName

        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": ClaudeModel.sonnet.rawValue,
            "max_tokens": 600,
            "stream": false,
            "temperature": 0.3,
            "system": """
            /* prompt redacted */
             \(langName).

            
            
            GLOSSARY:
            English term → \(langName) equivalent
            ...
            ## ASR
            misheard → correct
            ...

            Rules:
            - Always give your best guess for the show — never say you cannot identify
            - List at most 15 key terms (characters, slang, in-universe terms, key idioms)
            - For proper nouns:  \(langName) name from the localized version. If none exists, keep original English — 
            - For slang/in-universe terms:  \(langName) equivalents
            - 
            - Output ONLY this format. No explanations.
            """,
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

            // Parse SHOW: and GLOSSARY: sections
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let showRange = trimmed.range(of: "SHOW:"),
                  let glossaryRange = trimmed.range(of: "GLOSSARY:") else {
                // Fallback: treat entire response as topic (like old detectTopic)
                let topic = trimmed.components(separatedBy: "\n").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
                if topic.isEmpty { return nil }
                // No glossary parsed, but still return topic
                print("[Topic+Glossary] Parse failed, topic-only fallback: \"\(topic)\"")
                return nil
            }

            let showText = trimmed[showRange.upperBound..<glossaryRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let glossaryText = String(trimmed[glossaryRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !showText.isEmpty else { return nil }

            // Reject refusals
            let lower = showText.lowercased()
            if lower.contains("cannot") || lower.contains("can't") || lower.contains("unable to") {
                return nil
            }

            guard let glossary = Glossary.parse(
                raw: glossaryText, showName: showText, isUserProvided: false
            ) else {
                return nil
            }

            return (topic: showText, glossary: glossary)
        } catch {
            print("[Topic+Glossary] FAILED: \(error)")
            return nil
        }
    }

    /// Polish the full translated text: fix obvious translation errors using Sonnet + topic context.
    /// Non-streaming, user-triggered one-shot. Returns corrected text, or nil on failure.
    func polish(text: String, topic: String?, glossary: Glossary? = nil, language: TargetLanguage) async -> String? {
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
        if let glossary {
            system += glossary.promptFragment
        }

        let body: [String: Any] = [
            "model": ClaudeModel.sonnet.rawValue,
            "max_tokens": 4096,
            "stream": false,
            "temperature": 0.7,
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
            "temperature": 0.7,
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
            "temperature": 0.7,
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
            "temperature": 0.2,
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
