import Foundation
import SwiftData

// MARK: - Domain enums

/// Source of a history entry — which of the four Vox translation paths produced it.
enum HistoryKind: String, Codable, CaseIterable {
    case quickTranslation   // ⌘T clipboard/selection translation (single pair)
    case lectureSession     // Real-time lecture subtitles (streaming panel)
    case cinemaSession      // Real-time cinema subtitles (pop-on)

    var systemImage: String {
        switch self {
        case .quickTranslation: return "doc.text"
        case .lectureSession:   return "waveform"
        case .cinemaSession:    return "film"
        }
    }
}

/// Type of a post-processing artifact attached to a subtitle session.
enum ArtifactKind: String, Codable, CaseIterable {
    case polish
    case summary
    case studyNotes

    var displayName: String {
        switch self {
        case .polish:     return "Polish"
        case .summary:    return "Summary"
        case .studyNotes: return "Study Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .polish:     return "wand.and.stars"
        case .summary:    return "list.bullet"
        case .studyNotes: return "book"
        }
    }
}

/// One original/translated pair in a subtitle session transcript. Stored as
/// JSON inside `TranslationEntry.transcriptData` (external storage) to avoid
/// creating a SwiftData row per utterance for long lectures.
struct TranscriptLine: Codable, Hashable {
    /// Seconds from session start.
    var offset: TimeInterval
    /// Finalized source text (possibly after ASR cleanup).
    var source: String
    /// Translation. Empty string when translation was disabled at the time.
    var translated: String
}

// MARK: - Schema V1

enum HistorySchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TranslationEntry.self, PostProcessingArtifact.self]
    }
}

/// Stub plan — single v1 schema today. Future migrations append `SchemaV2`
/// and a `MigrationStage` between them so first real schema change doesn't
/// wipe saved history.
enum HistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [HistorySchemaV1.self]
    }

    static var stages: [MigrationStage] { [] }
}

// MARK: - Models

@Model
final class TranslationEntry {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var createdAt: Date
    var endedAt: Date?
    var durationSeconds: Double

    // Language & model metadata
    var sourceLangRaw: String?
    var targetLangRaw: String
    var modelRaw: String

    // Titles
    var autoTitle: String?
    var customTitle: String?
    var isGeneratingTitle: Bool

    // Archive
    var isArchived: Bool
    var archivedAt: Date?

    // Recovery flag — true when `reconcileCrashedSessions` repaired this entry
    // after an unclean app exit mid-session.
    var wasRecovered: Bool

    // Quick-translation payload (only for `.quickTranslation`)
    var quickSource: String?
    var quickTranslated: String?

    // Subtitle-session transcript — Codable `[TranscriptLine]` blob.
    // External storage keeps `TranslationEntry` rows small so list `@Query`
    // stays fast even with long lectures.
    @Attribute(.externalStorage) var transcriptData: Data?

    // Cinema-specific metadata
    var showName: String?
    var glossaryContent: String?

    // Post-processing children (Polish / Summary / Study Notes). 0..3 per session.
    @Relationship(deleteRule: .cascade, inverse: \PostProcessingArtifact.entry)
    var artifacts: [PostProcessingArtifact] = []

    init(
        kind: HistoryKind,
        targetLang: String,
        model: String,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
        self.durationSeconds = 0
        self.targetLangRaw = targetLang
        self.modelRaw = model
        self.isGeneratingTitle = false
        self.isArchived = false
        self.wasRecovered = false
    }

    // MARK: - Computed

    var kind: HistoryKind {
        HistoryKind(rawValue: kindRaw) ?? .quickTranslation
    }

    /// Title shown in UI — custom overrides auto, auto overrides fallback.
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let autoTitle, !autoTitle.isEmpty { return autoTitle }
        return fallbackTitle
    }

    /// Generated from creation date when nothing else is set.
    var fallbackTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        let stamp = formatter.string(from: createdAt)
        switch kind {
        case .quickTranslation: return "Translation — \(stamp)"
        case .lectureSession:   return "Lecture — \(stamp)"
        case .cinemaSession:    return "Cinema — \(stamp)"
        }
    }

    /// Short preview string for the list row. For point: source head.
    /// For sessions: first line of the decoded transcript.
    var listPreview: String {
        switch kind {
        case .quickTranslation:
            return (quickSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .lectureSession, .cinemaSession:
            return decodedTranscript.first?.source ?? ""
        }
    }

    /// Decoded transcript on demand. Returns empty array on decode failure.
    var decodedTranscript: [TranscriptLine] {
        guard let data = transcriptData else { return [] }
        return (try? JSONDecoder().decode([TranscriptLine].self, from: data)) ?? []
    }

    func setTranscript(_ lines: [TranscriptLine]) {
        transcriptData = try? JSONEncoder().encode(lines)
    }
}

@Model
final class PostProcessingArtifact {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var content: String
    var modelRaw: String
    var createdAt: Date
    var entry: TranslationEntry?

    init(kind: ArtifactKind, content: String, model: String) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.content = content
        self.modelRaw = model
        self.createdAt = .now
    }

    var kind: ArtifactKind {
        ArtifactKind(rawValue: kindRaw) ?? .polish
    }
}
