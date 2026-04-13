import Foundation
import SwiftData

/// Central store for translation history. Owns the SwiftData `ModelContainer`
/// and exposes ergonomic methods for each write path (quick translation, subtitle
/// sessions, post-processing artifacts). All operations run on `@MainActor`;
/// every caller in Vox is already MainActor-isolated.
///
/// On construction the store:
/// 1. Tries to build a file-based container under Application Support.
/// 2. Falls back to `.inMemory` if that fails — the app still launches,
///    history is simply ephemeral for this session.
/// 3. Reconciles any session that was mid-flight at the last launch
///    (`endedAt == nil`) by marking it recovered and closing it out.
@MainActor
final class HistoryStore {
    let container: ModelContainer
    /// True when we had to fall back to in-memory storage. Used by UI to show
    /// a banner that history won't persist for this session.
    private(set) var isEphemeral: Bool

    var mainContext: ModelContext { container.mainContext }

    /// In-memory draft of an active subtitle session. Lines are appended cheaply
    /// here and serialized to the SwiftData blob on `flushSession`/`finishSession`.
    private struct SessionDraft {
        var entryID: UUID
        var startTime: Date
        var lines: [TranscriptLine]
    }
    private var activeSessions: [UUID: SessionDraft] = [:]

    // MARK: - Init

    init() {
        let schema = Schema(versionedSchema: HistorySchemaV1.self)

        // Prefer a real file under the sandboxed Application Support directory.
        // Build the URL manually so we can create the parent directory first —
        // SwiftData won't create intermediate folders on its own.
        let result: (ModelContainer, Bool) = {
            do {
                let fm = FileManager.default
                let baseURL = try fm.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let voxDir = baseURL.appendingPathComponent("Vox", isDirectory: true)
                if !fm.fileExists(atPath: voxDir.path) {
                    try fm.createDirectory(at: voxDir, withIntermediateDirectories: true)
                }
                let storeURL = voxDir.appendingPathComponent("History.store")
                let config = ModelConfiguration(
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )
                let container = try ModelContainer(
                    for: schema,
                    migrationPlan: HistoryMigrationPlan.self,
                    configurations: config
                )
                print("[HistoryStore] Opened store at \(storeURL.path)")
                return (container, false)
            } catch {
                print("[HistoryStore] FATAL: file-based container failed: \(error)")
                // Fall back to in-memory — app keeps working, history is ephemeral.
                do {
                    let config = ModelConfiguration(
                        schema: schema,
                        isStoredInMemoryOnly: true
                    )
                    let container = try ModelContainer(
                        for: schema,
                        migrationPlan: HistoryMigrationPlan.self,
                        configurations: config
                    )
                    return (container, true)
                } catch {
                    fatalError("[HistoryStore] In-memory container also failed: \(error)")
                }
            }
        }()

        self.container = result.0
        self.isEphemeral = result.1

        reconcileCrashedSessions()
    }

    // MARK: - Quick translation

    /// Writes a completed quick-translation entry. Returns the new entry ID
    /// (for a follow-up title generation call), or `nil` when the input was
    /// rejected (too short / empty translation).
    @discardableResult
    func saveQuickTranslation(
        source: String,
        translated: String,
        sourceLang: String?,
        targetLang: String,
        model: String
    ) -> UUID? {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranslated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSource.count >= 3, !trimmedTranslated.isEmpty else { return nil }

        let entry = TranslationEntry(
            kind: .quickTranslation,
            targetLang: targetLang,
            model: model
        )
        entry.sourceLangRaw = sourceLang
        entry.quickSource = trimmedSource
        entry.quickTranslated = trimmedTranslated
        entry.endedAt = .now

        mainContext.insert(entry)
        saveSilently()
        return entry.id
    }

    /// Updates an existing quick-translation entry in place (used when the
    /// user retranslates the same source text to a different target language —
    /// keeps history tidy instead of spawning a duplicate row per retry).
    func updateQuickTranslation(
        entryID: UUID,
        translated: String,
        targetLang: String
    ) {
        guard let entry = fetchEntry(id: entryID) else { return }
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entry.quickTranslated = trimmed
        entry.targetLangRaw = targetLang
        saveSilently()
    }

    // MARK: - Subtitle sessions

    /// Creates a subtitle-session entry and opens an in-memory draft.
    /// Call at the top of `SubtitleService.start()`.
    @discardableResult
    func createSession(
        kind: HistoryKind,
        targetLang: String,
        model: String,
        showName: String?
    ) -> UUID {
        let entry = TranslationEntry(
            kind: kind,
            targetLang: targetLang,
            model: model
        )
        entry.showName = showName
        mainContext.insert(entry)
        saveSilently()

        activeSessions[entry.id] = SessionDraft(
            entryID: entry.id,
            startTime: entry.createdAt,
            lines: []
        )
        return entry.id
    }

    /// Append one translated pair to the active session's in-memory draft.
    /// The blob is written lazily (periodic `flushSession` or final
    /// `finishSession`) so live translation stays fast.
    func appendLine(sessionID: UUID, source: String, translated: String) {
        guard var draft = activeSessions[sessionID] else { return }
        let line = TranscriptLine(
            offset: Date().timeIntervalSince(draft.startTime),
            source: source,
            translated: translated
        )
        draft.lines.append(line)
        activeSessions[sessionID] = draft
    }

    /// Writes the current in-memory lines to the SwiftData blob without
    /// closing the session. Called periodically during a long session so
    /// crash recovery can reconstruct most of the transcript.
    func flushSession(sessionID: UUID) {
        guard let draft = activeSessions[sessionID],
              let entry = fetchEntry(id: sessionID) else { return }
        entry.setTranscript(draft.lines)
        saveSilently()
    }

    /// Closes out the session: writes the final blob, stamps `endedAt` and
    /// `durationSeconds`, captures the glossary snapshot, drops the draft.
    func finishSession(sessionID: UUID, glossary: String?) {
        guard let draft = activeSessions.removeValue(forKey: sessionID),
              let entry = fetchEntry(id: sessionID) else { return }
        entry.setTranscript(draft.lines)
        let endedAt = Date()
        entry.endedAt = endedAt
        entry.durationSeconds = endedAt.timeIntervalSince(draft.startTime)
        entry.glossaryContent = glossary
        saveSilently()
    }

    // MARK: - Post-processing

    /// Attaches a post-processing result (Polish / Summary / Study Notes) to
    /// an active (or recently ended) session.
    func attachArtifact(
        sessionID: UUID,
        kind: ArtifactKind,
        content: String,
        model: String
    ) {
        guard let entry = fetchEntry(id: sessionID) else { return }
        let artifact = PostProcessingArtifact(kind: kind, content: content, model: model)
        artifact.entry = entry
        entry.artifacts.append(artifact)
        mainContext.insert(artifact)
        saveSilently()
    }

    // MARK: - Actions

    func rename(entryID: UUID, to newTitle: String?) {
        guard let entry = fetchEntry(id: entryID) else { return }
        let trimmed = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.customTitle = (trimmed?.isEmpty == true) ? nil : trimmed
        saveSilently()
    }

    func archive(entryID: UUID) {
        guard let entry = fetchEntry(id: entryID) else { return }
        entry.isArchived = true
        entry.archivedAt = .now
        saveSilently()
    }

    func restore(entryID: UUID) {
        guard let entry = fetchEntry(id: entryID) else { return }
        entry.isArchived = false
        entry.archivedAt = nil
        saveSilently()
    }

    func delete(entryID: UUID) {
        guard let entry = fetchEntry(id: entryID) else { return }
        activeSessions.removeValue(forKey: entryID)
        mainContext.delete(entry)
        saveSilently()
    }

    // MARK: - Auto-title

    /// Requests a smart Claude-generated title for the given entry.
    /// - For Cinema sessions with a user-provided show name, skips the API
    ///   call and uses the show name directly.
    /// - Otherwise calls `SubtitleTranslator.generateTitle` in the background
    ///   via the current Keychain API key.
    /// - On success or fallback, persists the result and clears
    ///   `isGeneratingTitle`. Safe to call from any MainActor context;
    ///   it's fire-and-forget from the caller's perspective.
    func generateTitleIfNeeded(entryID: UUID) async {
        guard let entry = fetchEntry(id: entryID) else { return }

        // Avoid stomping existing titles or already-running generation.
        if entry.autoTitle != nil || entry.customTitle != nil { return }

        entry.isGeneratingTitle = true
        saveSilently()

        // Cinema short-circuit: user already gave us a canonical title.
        if entry.kind == .cinemaSession, let showName = entry.showName, !showName.isEmpty {
            entry.autoTitle = showName
            entry.isGeneratingTitle = false
            saveSilently()
            return
        }

        // Gather source text for the prompt.
        let sourceText: String = {
            switch entry.kind {
            case .quickTranslation:
                return entry.quickSource ?? ""
            case .lectureSession, .cinemaSession:
                return entry.decodedTranscript.map(\.source).joined(separator: " ")
            }
        }()

        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            entry.isGeneratingTitle = false
            saveSilently()
            return
        }

        let targetLang = TargetLanguage(rawValue: entry.targetLangRaw) ?? .english
        let kind = entry.kind
        let apiKey = (try? KeychainHelper().load()) ?? ""
        guard !apiKey.isEmpty else {
            entry.autoTitle = entry.fallbackTitle
            entry.isGeneratingTitle = false
            saveSilently()
            return
        }

        let translator = SubtitleTranslator(apiKey: apiKey)
        let generated = await translator.generateTitle(
            forTranscript: sourceText,
            kind: kind,
            language: targetLang
        )

        // Re-fetch in case the user renamed the entry while we were waiting.
        guard let refreshed = fetchEntry(id: entryID) else { return }
        refreshed.autoTitle = generated ?? refreshed.fallbackTitle
        refreshed.isGeneratingTitle = false
        saveSilently()
    }

    // MARK: - Internal helpers

    /// Fetch a single entry by UUID via a `FetchDescriptor` predicate.
    private func fetchEntry(id: UUID) -> TranslationEntry? {
        let descriptor = FetchDescriptor<TranslationEntry>(
            predicate: #Predicate { $0.id == id }
        )
        return try? mainContext.fetch(descriptor).first
    }

    private func saveSilently() {
        guard mainContext.hasChanges else { return }
        do {
            try mainContext.save()
        } catch {
            print("[HistoryStore] Save failed: \(error)")
        }
    }

    /// Repairs sessions that were mid-flight when the app exited without a
    /// clean `stop()` — stamps `endedAt` from the last transcript line (or
    /// `createdAt`) and marks them with `wasRecovered = true`.
    private func reconcileCrashedSessions() {
        let lectureRaw = HistoryKind.lectureSession.rawValue
        let cinemaRaw = HistoryKind.cinemaSession.rawValue
        let descriptor = FetchDescriptor<TranslationEntry>(
            predicate: #Predicate {
                $0.endedAt == nil &&
                ($0.kindRaw == lectureRaw || $0.kindRaw == cinemaRaw)
            }
        )
        guard let orphans = try? mainContext.fetch(descriptor), !orphans.isEmpty else { return }

        var repaired = 0
        for entry in orphans {
            let lines = entry.decodedTranscript
            if lines.isEmpty {
                // No content was flushed before the crash — just delete.
                mainContext.delete(entry)
                continue
            }
            let lastOffset = lines.last?.offset ?? 0
            entry.endedAt = entry.createdAt.addingTimeInterval(lastOffset)
            entry.durationSeconds = lastOffset
            entry.wasRecovered = true
            repaired += 1
        }
        saveSilently()
        print("[HistoryStore] Reconciled \(repaired) crashed session(s)")
    }
}
