import Foundation

/// Owns the history-session lifecycle: creates the `TranslationEntry`, runs
/// the periodic autosave, appends translated pairs, attaches post-processing
/// artifacts, and closes out the session on stop.
///
/// Two-phase teardown is deliberate. `endSession` writes the final blob (or
/// deletes an empty entry) but **does not** clear `activeSessionID`, because
/// late-arriving post-processing callbacks in `TranslationOrchestrator.processTranslation`
/// still need a valid ID to attach artifacts. The coordinator calls
/// `finalizeTeardown()` at the very end of `SubtitleService.stop()` once no
/// more artifact writes can land.
@MainActor
final class SubtitleSessionManager {
    weak var historyStore: HistoryStore?

    private(set) var activeSessionID: UUID?
    private(set) var sessionStartTime: Date?
    private(set) var sessionHadTranslation: Bool = false

    private var autosaveTask: Task<Void, Never>?

    init(historyStore: HistoryStore? = nil) {
        self.historyStore = historyStore
    }

    /// Creates a history entry for the session and starts the 15s autosave task.
    /// Safe to call when `historyStore` is nil — no-op.
    func beginSession(
        kind: HistoryKind,
        targetLang: String,
        model: String,
        showName: String?
    ) {
        guard let store = historyStore else { return }
        let id = store.createSession(
            kind: kind,
            targetLang: targetLang,
            model: model,
            showName: showName
        )
        activeSessionID = id
        sessionStartTime = .now
        sessionHadTranslation = false

        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                guard let sid = self.activeSessionID else { return }
                self.historyStore?.flushSession(sessionID: sid)
            }
        }
    }

    /// Writes the final transcript blob (or deletes an empty entry) and cancels
    /// the autosave task. **Does not** clear `activeSessionID` — call
    /// `finalizeTeardown()` after all late callbacks have had a chance to run.
    func endSession(glossaryContent: String?) {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard let sid = activeSessionID, let store = historyStore else { return }
        if sessionHadTranslation {
            store.finishSession(sessionID: sid, glossary: glossaryContent)
            Task { [weak store] in
                await store?.generateTitleIfNeeded(entryID: sid)
            }
        } else {
            // No successful translation — don't pollute history with an empty
            // ASR-only run.
            store.delete(entryID: sid)
        }
    }

    /// Clears `activeSessionID` / `sessionStartTime` / `sessionHadTranslation`.
    /// Called last in `SubtitleService.stop()`.
    func finalizeTeardown() {
        activeSessionID = nil
        sessionStartTime = nil
        sessionHadTranslation = false
    }

    /// Append one translated pair. Sets `sessionHadTranslation = true` so stop()
    /// knows to finish (not delete) the entry.
    func appendPair(source: String, translated: String) {
        guard let sid = activeSessionID else { return }
        historyStore?.appendLine(sessionID: sid, source: source, translated: translated)
        sessionHadTranslation = true
    }

    /// Attaches a post-processing artifact (polish / summary / study notes) to
    /// the active (or recently-ended) entry. Safe to call after `endSession`
    /// and before `finalizeTeardown`.
    func attachArtifact(kind: ArtifactKind, content: String, model: String) {
        guard let sid = activeSessionID else { return }
        historyStore?.attachArtifact(sessionID: sid, kind: kind, content: content, model: model)
    }
}
