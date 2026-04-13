import Foundation

/// Translates subtitle text via Claude API with streaming support.
final class SubtitleTranslator {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - ASR Cleanup (Phase 2)

    /// Result of sanitizing Haiku output in correctASRTerms.
    /// `.accept` means the cleaned text passed all guardrails.
    /// `.reject` means a guardrail fired — caller should use the original text.
    enum ASRCleanupDecision: Equatable {
        case accept(String)
        case reject(reason: String)
    }

    /// Client-side sanitizer for Haiku output in `correctASRTerms`.
    /// Blocks empty output, length hallucinations, and non-ASCII leaks
    /// (translation escape). Trim is applied before length checks.
    /// See docs/superpowers/specs/2026-04-10-asr-cleanup-design.md §Output Sanitizer.
    static func sanitizeCleanupResult(original: String, cleaned: String) -> ASRCleanupDecision {
        let stripped = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Empty or whitespace-only — model returned nothing usable.
        if stripped.isEmpty {
            return .reject(reason: "empty")
        }

        // 2. Length hallucination — model rephrased, completed, or expanded.
        //    Compare against 1.5x the original length.
        let maxAllowed = Int(Double(original.count) * 1.5)
        if stripped.count > maxAllowed {
            return .reject(reason: "length hallucination (IN:\(original.count) OUT:\(stripped.count))")
        }

        // 3. Non-ASCII leak — cleaned contains a non-ASCII character that
        //    was NOT present in the original. Common failure: model slipped
        //    into translating despite the "stay in English" rule.
        let originalNonASCII = Set(original.unicodeScalars.filter { !$0.isASCII })
        for scalar in stripped.unicodeScalars where !scalar.isASCII {
            if !originalNonASCII.contains(scalar) {
                let hex = String(scalar.value, radix: 16, uppercase: true)
                return .reject(reason: "non-ASCII leak (U+\(hex))")
            }
        }

        return .accept(stripped)
    }

    /// Phase 2 ASR cleanup stage. Corrects misheard proper nouns and
    /// show-specific terms in raw ASR English text using the per-session
    /// glossary. Returns the corrected text, or the original text on any
    /// non-cancellation failure (timeout, HTTP error, parse error, sanitizer
    /// rejection). Cancellation is rethrown so the caller's Task cancels
    /// cleanly.
    ///
    /// Invariant: this method never calls the main translation API, never
    /// touches SubtitleService.rateLimitUntil, and never mutates any state
    /// outside its own scope. It is safe to drop in front of any final
    /// translation call; at worst it is a no-op.
    ///
    /// See docs/superpowers/specs/2026-04-10-asr-cleanup-design.md.
    func correctASRTerms(text: String, glossary: Glossary, topic: String?) async throws -> String {
        // Empty input → skip API call.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 3

        // Build the system prompt. Structure: show context, list of correct
        // English terms, optional list of known mishearings, strict rules.
        let englishTermsBlock = glossary.englishTerms.joined(separator: "\n")

        var system = """
        /* prompt redacted */ \
        , so character \
        
        """

        if let topic {
            system += "\n\nShow: \(topic)"
        }

        system += "\n\n\n\(englishTermsBlock)"

        if let hints = glossary.asrHints, !hints.isEmpty {
            // glossary.asrHints is stored as a single comma-joined string like
            // "soups → supes, fought → Vought". Render one pair per line so
            // Haiku has an easier time parsing the replacement list.
            let hintLines = hints
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            system += "\n\n\n\(hintLines)"
        }

        system += """


        STRICT RULES:
        - 
        - 
        - 
        - 
        - 
        - 
        - 
        - 

        
        """

        let body: [String: Any] = [
            "model": ClaudeModel.haiku.rawValue,
            "max_tokens": 200,
            "stream": false,
            "temperature": 0.0,
            "system": system,
            "messages": [["role": "user", "content": text]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("[Cleanup] body encode failed: \(error) — using raw")
            return text
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Cleanup] no HTTPURLResponse — using raw")
                return text
            }

            if httpResponse.statusCode != 200 {
                print("[Cleanup] HTTP \(httpResponse.statusCode) — using raw")
                return text
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let rawResult = firstBlock["text"] as? String else {
                print("[Cleanup] parse fail — using raw")
                return text
            }

            switch Self.sanitizeCleanupResult(original: text, cleaned: rawResult) {
            case .accept(let cleaned):
                if cleaned == text {
                    print("[Cleanup] unchanged")
                } else {
                    print("[Cleanup] FIX: \"\(cleaned)\"")
                }
                return cleaned
            case .reject(let reason):
                print("[Cleanup] REJECTED: \(reason) — using raw")
                return text
            }
        } catch {
            // Cancellation must propagate so the outer finalTask cancels cleanly.
            if error is CancellationError {
                print("[Cleanup] cancelled")
                throw error
            }
            if let urlErr = error as? URLError {
                if urlErr.code == .cancelled {
                    print("[Cleanup] cancelled")
                    throw error
                }
                if urlErr.code == .timedOut {
                    print("[Cleanup] TIMEOUT — using raw")
                    return text
                }
            }
            print("[Cleanup] network error: \(error) — using raw")
            return text
        }
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

    // MARK: - History Title Generation

    /// Generate a short, descriptive title for a saved history entry.
    /// Uses Haiku with a minimal system prompt. Returns the raw title
    /// or `nil` on timeout / HTTP error / empty refusal.
    ///
    /// Used by `HistoryStore.generateTitleIfNeeded` as fire-and-forget
    /// background work after a quick translation or subtitle session is
    /// persisted. Cinema sessions with a user-provided show name bypass
    /// this method entirely.
    func generateTitle(
        forTranscript text: String,
        kind: HistoryKind,
        language: TargetLanguage
    ) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Cap the user message at ~1500 characters — plenty for Haiku to
        // identify a topic without burning tokens on long lectures.
        let capped = trimmed.count > 1500 ? String(trimmed.prefix(1500)) : trimmed

        var request = URLRequest(url: Constants.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 5

        let kindLabel: String = {
            switch kind {
            case .quickTranslation: return "quick"
            case .lectureSession:   return "lecture"
            case .cinemaSession:    return "cinema"
            }
        }()

        let system = """
        /* prompt redacted */
        Rules:
        - 
        - No quotes, no trailing punctuation
        - 
        - 
        """

        let userContent = "\(capped)\n\nLanguage: \(language.displayName)\nType: \(kindLabel)"

        let body: [String: Any] = [
            "model": ClaudeModel.haiku.rawValue,
            "max_tokens": 30,
            "stream": false,
            "temperature": 0.4,
            "system": system,
            "messages": [["role": "user", "content": userContent]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let raw = firstBlock["text"] as? String else {
                return nil
            }
            var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip leading/trailing quotes if the model added them.
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}\u{00AB}\u{00BB}'"))
            // Strip trailing punctuation.
            while let last = title.last, ".!?,;:".contains(last) {
                title.removeLast()
            }
            if title.isEmpty { return nil }
            let lower = title.lowercased()
            if lower.contains("cannot") || lower.contains("can't") || lower.contains("unable") {
                return nil
            }
            return title
        } catch {
            print("[HistoryTitle] FAILED: \(error)")
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

        let systemPrompt = """
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

        
        """

        // Fallback chain: try Sonnet first (best quality), then Haiku (usually available
        // under Sonnet overload), then Opus (independent capacity pool, last resort).
        // Anthropic recommends exponential backoff but different models have independent
        // capacity, so falling over to a sibling model is faster than waiting.
        let fallbackModels: [String] = [
            ClaudeModel.sonnet.rawValue,
            ClaudeModel.haiku.rawValue,
            "claude-opus-4-1-20250805"
        ]

        for modelID in fallbackModels {
            if Task.isCancelled { return nil }

            var request = URLRequest(url: Constants.apiURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = 15

            let body: [String: Any] = [
                "model": modelID,
                "max_tokens": 500,
                "stream": false,
                "temperature": 0.3,
                "system": systemPrompt,
                "messages": [["role": "user", "content": "Show: \(showName)"]]
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                print("[Glossary] FAILED: body encode — \(error)")
                return nil
            }

            print("[Glossary] Trying model: \(modelID)")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    print("[Glossary] \(modelID): no HTTPURLResponse — trying next model")
                    continue
                }
                if httpResponse.statusCode != 200 {
                    let bodyPreview = String(data: data, encoding: .utf8)?.prefix(400) ?? "<non-utf8>"
                    // 429 rate limit, 529 overloaded, 503 unavailable — try next model
                    if httpResponse.statusCode == 429 || httpResponse.statusCode == 529 || httpResponse.statusCode == 503 {
                        print("[Glossary] \(modelID) transient HTTP \(httpResponse.statusCode) — trying next model. Body: \(bodyPreview)")
                        continue
                    }
                    // Hard error (bad request, auth, etc.) — no point trying siblings
                    print("[Glossary] FAILED: HTTP \(httpResponse.statusCode) — \(bodyPreview)")
                    return nil
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let bodyPreview = String(data: data, encoding: .utf8)?.prefix(400) ?? "<non-utf8>"
                    print("[Glossary] FAILED: JSON parse — \(bodyPreview)")
                    return nil
                }
                guard let content = json["content"] as? [[String: Any]],
                      let firstBlock = content.first,
                      let result = firstBlock["text"] as? String else {
                    print("[Glossary] FAILED: missing content/text in response — json keys: \(json.keys)")
                    return nil
                }

                guard let glossary = Glossary.parse(raw: result, showName: showName, isUserProvided: isUserProvided) else {
                    let rawPreview = result.prefix(400)
                    print("[Glossary] \(modelID) parse returned nil — raw: \(rawPreview) — trying next model")
                    continue
                }
                // Sanity check: Claude sometimes returns a tiny/empty glossary
                // (model laziness or prompt mis-interpretation). Require at least
                // 5 term lines to consider the response usable; otherwise fallback
                // to the next model in the chain.
                let termLineCount = glossary.content.components(separatedBy: "\n")
                    .filter { $0.contains("→") || $0.contains("—") }
                    .count
                if termLineCount < 5 {
                    let rawPreview = result.prefix(400)
                    print("[Glossary] \(modelID) returned only \(termLineCount) term lines — trying next model. Raw: \(rawPreview)")
                    continue
                }
                print("[Glossary] Success on \(modelID) — \(termLineCount) term lines")
                return glossary
            } catch {
                // Cancelled URLSession (e.g. user switched language mid-request).
                // Not an error — just a superseded request.
                if (error as? URLError)?.code == .cancelled {
                    print("[Glossary] Cancelled (superseded)")
                    return nil
                }
                print("[Glossary] \(modelID) network error — trying next model: \(error)")
                continue
            }
        }

        print("[Glossary] FAILED: all models in fallback chain exhausted")
        return nil
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
