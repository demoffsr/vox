import SwiftUI

/// Sheet presented when the user opens a history entry. Chrome mirrors the
/// lecture translation window: title bar → gradient divider → optional tab
/// bar → scroll content → gradient divider → bottom bar.
///
/// - **Point translations**: two stacked sections, Source and Translation.
/// - **Subtitle sessions**: tab bar with Subtitles + available post-processing
///   artifacts (Polish / Summary / Study Notes), rendered on demand.
///
/// Rename, Archive, Share, Export land in Step 7. This view is read-only
/// for now aside from the close action.
struct HistoryDetailView: View {
    let entry: TranslationEntry
    var onClose: () -> Void
    var onRename: () -> Void = {}
    var onArchive: () -> Void = {}
    var onRestore: () -> Void = {}
    var onDelete: () -> Void = {}

    @State private var activeTab: HistoryDetailTab = .transcript
    @State private var shareURLs: [HistoryExportFormat: URL] = [:]

    private var availableTabs: [HistoryDetailTab] {
        var tabs: [HistoryDetailTab] = [.transcript]
        // Order artifacts Polish → Summary → Study Notes, matching TranslationStreamView.
        let preferredOrder: [ArtifactKind] = [.polish, .summary, .studyNotes]
        let present = Set(entry.artifacts.map(\.kind))
        for kind in preferredOrder where present.contains(kind) {
            tabs.append(.artifact(kind))
        }
        return tabs
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            GradientDivider()

            if entry.kind != .quickTranslation, availableTabs.count > 1 {
                HistoryTabBar(tabs: availableTabs, active: $activeTab)
                GradientDivider()
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    switch entry.kind {
                    case .quickTranslation:
                        quickContent
                    case .lectureSession, .cinemaSession:
                        sessionContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GradientDivider()
            bottomBar
        }
        .frame(width: 580, height: 560)
        .background {
            if #available(macOS 26.0, *) {
                Rectangle().fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 16))
            } else {
                Color.black.opacity(0.35)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind.systemImage)
                .font(.system(size: 13))
                .foregroundStyle(VoxTokens.Ink.muted)
            Text(entry.displayTitle)
                .font(VoxTokens.Typo.body)
                .foregroundStyle(VoxTokens.Ink.primary)
                .lineLimit(1)
            if entry.isGeneratingTitle {
                ProgressView()
                    .controlSize(.mini)
                    .tint(VoxTokens.Ink.subtle)
            }
            Spacer()
            metaLabel
            VoxCircleIconButton(icon: "xmark", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var metaLabel: some View {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let date = fmt.string(from: entry.createdAt)
        let lang = entry.targetLangRaw.isEmpty ? "" : " · → \(entry.targetLangRaw)"
        return Text("\(date)\(lang)")
            .font(VoxTokens.Typo.tiny)
            .foregroundStyle(VoxTokens.Ink.faint)
            .lineLimit(1)
    }

    // MARK: - Point content

    @ViewBuilder
    private var quickContent: some View {
        sectionLabel("Original")
        Text(entry.quickSource ?? "")
            .font(VoxTokens.Typo.bodyLg)
            .foregroundStyle(VoxTokens.Ink.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)

        GradientDivider()

        sectionLabel("Translation")
        Text(entry.quickTranslated ?? "")
            .font(VoxTokens.Typo.bodyLg)
            .foregroundStyle(VoxTokens.Ink.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Session content (transcript + artifacts)

    @ViewBuilder
    private var sessionContent: some View {
        switch activeTab {
        case .transcript:
            transcriptList
        case .artifact(let kind):
            if let artifact = entry.artifacts.first(where: { $0.kind == kind }) {
                artifactBody(artifact)
            } else {
                Text("No content.")
                    .font(VoxTokens.Typo.body)
                    .foregroundStyle(VoxTokens.Ink.muted)
            }
        }
    }

    @ViewBuilder
    private var transcriptList: some View {
        let lines = entry.decodedTranscript
        if lines.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 22))
                    .foregroundStyle(VoxTokens.Ink.subtle)
                Text("No transcript recorded.")
                    .font(VoxTokens.Typo.body)
                    .foregroundStyle(VoxTokens.Ink.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.source)
                            .font(VoxTokens.Typo.body)
                            .foregroundStyle(VoxTokens.Ink.tertiary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !line.translated.isEmpty {
                            Text(line.translated)
                                .font(VoxTokens.Typo.bodyLg)
                                .foregroundStyle(VoxTokens.Ink.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artifactBody(_ artifact: PostProcessingArtifact) -> some View {
        sectionLabel(artifact.kind.displayName)
        Text(artifact.content)
            .font(VoxTokens.Typo.bodyLg)
            .foregroundStyle(VoxTokens.Ink.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            VoxCapsuleButton("Rename", icon: "pencil", action: onRename)

            Menu {
                Button("Copy as Plain Text") { copyAll(.plainText) }
                Button("Copy as Markdown") { copyAll(.markdown) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                    Text("Copy").font(VoxTokens.Typo.small)
                }
                .foregroundStyle(VoxTokens.Ink.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(VoxTokens.Ink.trace))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let url = shareURLs[.markdown] {
                ShareLink(item: url, preview: SharePreview(entry.displayTitle)) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                        Text("Share").font(VoxTokens.Typo.small)
                    }
                    .foregroundStyle(VoxTokens.Ink.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(VoxTokens.Ink.trace))
                }
                .buttonStyle(.plain)
            } else {
                VoxCapsuleButton("Share", icon: "square.and.arrow.up") {
                    prepareShareURL(format: .markdown)
                }
            }

            Menu {
                Button("Save as Plain Text (.txt)") { saveAs(.plainText) }
                Button("Save as Markdown (.md)") { saveAs(.markdown) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 11, weight: .semibold))
                    Text("Export").font(VoxTokens.Typo.small)
                }
                .foregroundStyle(VoxTokens.Ink.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(VoxTokens.Ink.trace))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if entry.isArchived {
                VoxCapsuleButton("Restore", icon: "arrow.uturn.backward") {
                    onRestore(); onClose()
                }
                VoxCapsuleButton("Delete", icon: "trash") {
                    onDelete()
                }
            } else {
                VoxCapsuleButton("Archive", icon: "archivebox") {
                    onArchive(); onClose()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Bottom bar actions

    private func prepareShareURL(format: HistoryExportFormat) {
        do {
            let url = try HistoryExporter.writeTemp(entry, format: format)
            shareURLs[format] = url
        } catch {
            print("[HistoryDetailView] Share prep failed: \(error)")
        }
    }

    private func copyAll(_ format: HistoryExportFormat) {
        let text = HistoryExporter.render(entry, format: format)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveAs(_ format: HistoryExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(entry.displayTitle).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = HistoryExporter.render(entry, format: format)
        try? content.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(VoxTokens.Ink.faint)
            .tracking(0.6)
    }
}
