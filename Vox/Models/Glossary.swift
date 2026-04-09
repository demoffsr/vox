import Foundation

enum GlossaryConfidence {
    case strict   // User explicitly named the show
    case soft     // Auto-detected from dialogue
}

struct Glossary {
    let showName: String
    let content: String           // Formatted glossary lines (≤30 lines)
    let asrHints: String?         // "soups → supes, vote → Vought"
    let confidence: GlossaryConfidence

    /// Formatted for injection into translation system prompt
    var promptFragment: String {
        switch confidence {
        case .strict:
            // Split lines: [?]-marked terms get soft wording, rest are strict
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            let strict = lines.filter { !$0.contains("[?]") }
            let uncertain = lines.filter { $0.contains("[?]") }
                .map { $0.replacingOccurrences(of: " [?]", with: "") }

            var result = "\nGLOSSARY — ALWAYS use these exact translations for \"\(showName)\":"
            if !strict.isEmpty {
                result += "\n" + strict.joined(separator: "\n")
            }
            if !uncertain.isEmpty {
                result += "\nPrefer these translations when applicable:"
                result += "\n" + uncertain.joined(separator: "\n")
            }
            return result
        case .soft:
            return """
            \nGLOSSARY — When translating content that appears to be from "\(showName)", prefer these translations:
            \(content)
            """
        }
    }

    /// ASR correction hints for injection into translateStreaming system prompt
    var asrPromptFragment: String? {
        guard let asrHints, !asrHints.isEmpty else { return nil }
        return "\nNote: ASR may have misheard these words: \(asrHints)"
    }

    // MARK: - Parsing

    /// Parse raw Claude response into a Glossary.
    /// Expected format: glossary lines, then optional `## ASR` section.
    static func parse(
        raw: String,
        showName: String,
        isUserProvided: Bool
    ) -> Glossary? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.components(separatedBy: "## ASR")
        let glossaryRaw = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)

        // Cap at 30 lines
        let lines = glossaryRaw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let capped = Array(lines.prefix(30)).joined(separator: "\n")
        guard !capped.isEmpty else { return nil }

        let asrHints: String? = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            : nil

        return Glossary(
            showName: showName,
            content: capped,
            asrHints: asrHints,
            confidence: isUserProvided ? .strict : .soft
        )
    }
}
