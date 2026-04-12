import SwiftUI
import SwiftData

/// Self-contained section for the redesigned Settings. Provides:
/// - `Active | Archived` segmented filter
/// - Inline search on title + source text
/// - List of `HistoryRowView` with tap-to-open, context menu (rename,
///   share, export, archive / restore / delete)
/// - Sheet presentation for `HistoryDetailView`
struct HistorySectionView: View {
    @Query(
        filter: #Predicate<TranslationEntry> { !$0.isArchived },
        sort: [SortDescriptor(\TranslationEntry.createdAt, order: .reverse)]
    )
    private var activeEntries: [TranslationEntry]

    @Query(
        filter: #Predicate<TranslationEntry> { $0.isArchived },
        sort: [SortDescriptor(\TranslationEntry.archivedAt, order: .reverse)]
    )
    private var archivedEntries: [TranslationEntry]

    @Environment(\.modelContext) private var modelContext

    @State private var filter: Filter = .active
    @State private var searchText: String = ""
    @State private var selection: HistorySelection?
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    @State private var deleteCandidate: HistorySelection?

    private var currentList: [TranslationEntry] {
        let source = filter == .active ? activeEntries : archivedEntries
        guard !searchText.isEmpty else { return source }
        let needle = searchText.lowercased()
        return source.filter { entry in
            let title = entry.displayTitle.lowercased()
            if title.contains(needle) { return true }
            let preview = entry.listPreview.lowercased()
            return preview.contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            GradientDivider().padding(.horizontal, 14)

            if currentList.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(currentList.enumerated()), id: \.element.id) { index, entry in
                        rowWithActions(entry)
                        if index < currentList.count - 1 {
                            GradientDivider().padding(.horizontal, 14)
                        }
                    }
                }
            }
        }
        .sheet(item: $selection) { sel in
            if let entry = fetchSelection(sel.id) {
                HistoryDetailView(
                    entry: entry,
                    onClose: { selection = nil },
                    onRename: { startRename(entry) },
                    onArchive: { archive(entry) },
                    onRestore: { restore(entry) },
                    onDelete: {
                        selection = nil
                        deleteCandidate = HistorySelection(id: entry.id)
                    }
                )
            }
        }
        .alert(
            "Delete this translation?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            presenting: deleteCandidate
        ) { sel in
            Button("Delete", role: .destructive) {
                if let entry = fetchSelection(sel.id) {
                    delete(entry)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Subviews

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(VoxTokens.Ink.subtle)
                TextField("Search history", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(VoxTokens.Typo.small)
                    .foregroundStyle(VoxTokens.Ink.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: VoxTokens.Radius.sm, style: .continuous)
                    .fill(VoxTokens.Ink.trace)
            )

            Picker("", selection: $filter) {
                Text("Active").tag(Filter.active)
                Text("Archive").tag(Filter.archived)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func rowWithActions(_ entry: TranslationEntry) -> some View {
        HistoryRowView(entry: entry) {
            selection = HistorySelection(id: entry.id)
        }
        .contextMenu {
            contextMenuButtons(entry)
        }
        .popover(
            isPresented: Binding(
                get: { renamingID == entry.id },
                set: { if !$0 { renamingID = nil } }
            ),
            arrowEdge: .top
        ) {
            renamePopover(entry)
        }
    }

    @ViewBuilder
    private func contextMenuButtons(_ entry: TranslationEntry) -> some View {
        Button("Open") { selection = HistorySelection(id: entry.id) }
        Divider()
        Button("Rename") { startRename(entry) }
        Menu("Share") {
            Button("Copy as Plain Text") { copyToPasteboard(entry, format: .plainText) }
            Button("Copy as Markdown") { copyToPasteboard(entry, format: .markdown) }
        }
        Menu("Export") {
            Button("Save as Plain Text (.txt)") { exportSavePanel(entry, format: .plainText) }
            Button("Save as Markdown (.md)") { exportSavePanel(entry, format: .markdown) }
        }
        Divider()
        if entry.isArchived {
            Button("Restore") { restore(entry) }
            Button("Delete", role: .destructive) {
                deleteCandidate = HistorySelection(id: entry.id)
            }
        } else {
            Button("Archive") { archive(entry) }
        }
    }

    private func renamePopover(_ entry: TranslationEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename")
                .font(VoxTokens.Typo.tiny)
                .foregroundStyle(VoxTokens.Ink.faint)
                .tracking(0.4)
            TextField("Title", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { commitRename(entry) }
            HStack {
                Spacer()
                VoxCapsuleButton("Cancel") { renamingID = nil }
                VoxCapsuleButton("Save") { commitRename(entry) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .active
                  ? "clock.arrow.circlepath"
                  : "archivebox")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(VoxTokens.Ink.subtle)
            Text(filter == .active
                 ? "No saved translations yet"
                 : "No archived translations")
                .font(VoxTokens.Typo.small)
                .foregroundStyle(VoxTokens.Ink.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func startRename(_ entry: TranslationEntry) {
        renameDraft = entry.customTitle ?? entry.autoTitle ?? entry.displayTitle
        renamingID = entry.id
    }

    private func commitRename(_ entry: TranslationEntry) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.customTitle = trimmed.isEmpty ? nil : trimmed
        try? modelContext.save()
        renamingID = nil
    }

    private func archive(_ entry: TranslationEntry) {
        entry.isArchived = true
        entry.archivedAt = .now
        try? modelContext.save()
    }

    private func restore(_ entry: TranslationEntry) {
        entry.isArchived = false
        entry.archivedAt = nil
        try? modelContext.save()
    }

    private func delete(_ entry: TranslationEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
    }

    private func copyToPasteboard(_ entry: TranslationEntry, format: HistoryExportFormat) {
        let text = HistoryExporter.render(entry, format: format)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportSavePanel(_ entry: TranslationEntry, format: HistoryExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(entry.displayTitle).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        let content = HistoryExporter.render(entry, format: format)
        try? content.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func fetchSelection(_ id: UUID) -> TranslationEntry? {
        if let hit = activeEntries.first(where: { $0.id == id }) { return hit }
        return archivedEntries.first(where: { $0.id == id })
    }
}

// MARK: - Local helper types

private enum Filter: Hashable {
    case active
    case archived
}

/// Plain Sendable wrapper used with `sheet(item:)`. We can't use
/// `TranslationEntry` directly because `@Model` classes are MainActor-isolated
/// and can't satisfy the Sendable metatype requirement of `Identifiable`
/// for `sheet(item:)`.
private struct HistorySelection: Identifiable, Hashable {
    let id: UUID
}
