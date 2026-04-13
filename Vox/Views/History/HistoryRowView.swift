import SwiftUI

/// One row in the history list. Type-icon disc on the left, title + preview
/// in the middle, relative timestamp on the right. Follows the lecture window
/// visual language (VoxTokens + glass hierarchy).
struct HistoryRowView: View {
    let entry: TranslationEntry
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                kindIcon

                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    previewLine
                }

                Spacer(minLength: 8)

                Text(entry.createdAt.formatted(.relative(presentation: .named)))
                    .font(VoxTokens.Typo.tiny)
                    .foregroundStyle(VoxTokens.Ink.faint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subviews

    private var kindIcon: some View {
        ZStack {
            Circle()
                .fill(VoxTokens.Ink.hairline)
                .frame(width: 28, height: 28)
            Image(systemName: entry.kind.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VoxTokens.Ink.tertiary)
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(entry.displayTitle)
                .font(VoxTokens.Typo.body)
                .foregroundStyle(VoxTokens.Ink.primary)
                .lineLimit(1)
            if entry.isGeneratingTitle {
                ProgressView()
                    .controlSize(.mini)
                    .tint(VoxTokens.Ink.subtle)
            }
        }
    }

    private var previewLine: some View {
        Text(entry.listPreview)
            .font(VoxTokens.Typo.tiny)
            .foregroundStyle(VoxTokens.Ink.muted)
            .lineLimit(1)
    }
}
