import Foundation
import UniformTypeIdentifiers

/// Export formats available from the history detail view.
enum HistoryExportFormat: String, CaseIterable, Identifiable {
    case plainText
    case markdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plainText: return "Plain text (.txt)"
        case .markdown:  return "Markdown (.md)"
        }
    }

    var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown:  return "md"
        }
    }

    var contentType: UTType {
        switch self {
        case .plainText: return .plainText
        case .markdown:  return UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

/// Renders and writes history entries in user-friendly formats. Plain text
/// is a minimal "pairs only" dump. Markdown includes front-matter with
/// session metadata and `##` sections for any attached post-processing
/// artifacts (Polish / Summary / Study Notes).
enum HistoryExporter {
    static func render(_ entry: TranslationEntry, format: HistoryExportFormat) -> String {
        switch format {
        case .plainText: return renderPlainText(entry)
        case .markdown:  return renderMarkdown(entry)
        }
    }

    /// Writes a rendered export to a temporary file with a safe filename
    /// and returns the URL. Callers use this URL with `ShareLink` — the
    /// file stays in the temp dir until the OS cleans it up.
    static func writeTemp(_ entry: TranslationEntry, format: HistoryExportFormat) throws -> URL {
        let content = render(entry, format: format)
        let sanitized = sanitizeFilename(entry.displayTitle)
        let filename = "\(sanitized).\(format.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Plain text

    private static func renderPlainText(_ entry: TranslationEntry) -> String {
        switch entry.kind {
        case .quickTranslation:
            let src = entry.quickSource ?? ""
            let dst = entry.quickTranslated ?? ""
            return "\(src)\n\n---\n\n\(dst)\n"

        case .lectureSession, .cinemaSession:
            let lines = entry.decodedTranscript
            var out = ""
            for line in lines {
                out += line.source
                out += "\n"
                if !line.translated.isEmpty {
                    out += line.translated
                    out += "\n"
                }
                out += "\n"
            }
            return out
        }
    }

    // MARK: - Markdown

    private static func renderMarkdown(_ entry: TranslationEntry) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        var out = "# \(entry.displayTitle)\n\n"

        // Metadata block
        var meta: [String] = []
        meta.append("created: \(fmt.string(from: entry.createdAt))")
        if let ended = entry.endedAt {
            meta.append("ended: \(fmt.string(from: ended))")
        }
        if entry.durationSeconds > 0 {
            meta.append("duration: \(formatDuration(entry.durationSeconds))")
        }
        if let src = entry.sourceLangRaw {
            meta.append("language: \(src) → \(entry.targetLangRaw)")
        } else if !entry.targetLangRaw.isEmpty {
            meta.append("target: \(entry.targetLangRaw)")
        }
        if !entry.modelRaw.isEmpty {
            meta.append("model: \(entry.modelRaw)")
        }
        if let show = entry.showName {
            meta.append("show: \(show)")
        }
        out += "_\(meta.joined(separator: " · "))_\n\n"

        switch entry.kind {
        case .quickTranslation:
            out += "## Original\n\n\(entry.quickSource ?? "")\n\n"
            out += "## Translation\n\n\(entry.quickTranslated ?? "")\n"

        case .lectureSession, .cinemaSession:
            out += "## Transcript\n\n"
            let lines = entry.decodedTranscript
            if lines.isEmpty {
                out += "_No transcript recorded._\n\n"
            } else {
                for line in lines {
                    out += "> \(line.source)\n"
                    if !line.translated.isEmpty {
                        out += ">\n> **\(line.translated)**\n"
                    }
                    out += "\n"
                }
            }

            // Post-processing artifacts, ordered Polish → Summary → Study Notes.
            let ordered: [ArtifactKind] = [.polish, .summary, .studyNotes]
            for kind in ordered {
                if let artifact = entry.artifacts.first(where: { $0.kind == kind }) {
                    out += "## \(kind.displayName)\n\n\(artifact.content)\n\n"
                }
            }
        }

        return out
    }

    // MARK: - Helpers

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private static func sanitizeFilename(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*|\"<>\n\r\t")
        let cleaned = title
            .components(separatedBy: bad)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let collapsed = cleaned.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        if collapsed.isEmpty { return "Untitled" }
        return String(collapsed.prefix(80))
    }
}
