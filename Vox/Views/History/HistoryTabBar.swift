import SwiftUI

/// Read-only tab bar used by `HistoryDetailView`. Mirrors the active-state
/// styling of `TranslationStreamView.tabBar` (pill with 0.12 opacity fill,
/// inactive 0.4 foreground) but without drag&drop, close, or processing
/// spinners — history entries are immutable views over finished content.
struct HistoryTabBar: View {
    let tabs: [HistoryDetailTab]
    @Binding var active: HistoryDetailTab
    @State private var hovered: HistoryDetailTab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.id) { tab in
                tabButton(for: tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tabButton(for tab: HistoryDetailTab) -> some View {
        let isActive = tab == active
        return Button(action: { active = tab }) {
            HStack(spacing: 5) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
            }
            .foregroundStyle(isActive ? .white.opacity(0.9) : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: VoxTokens.Radius.xs, style: .continuous)
                    .fill(isActive
                          ? Color.white.opacity(0.12)
                          : (hovered == tab ? Color.white.opacity(0.06) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? tab : nil }
    }
}

// MARK: - Tab descriptor

/// A specific section shown inside `HistoryDetailView` for subtitle-session
/// entries. For quick translations no tab bar is rendered at all.
enum HistoryDetailTab: Hashable, Identifiable {
    case transcript
    case artifact(ArtifactKind)

    var id: String {
        switch self {
        case .transcript: return "transcript"
        case .artifact(let kind): return "artifact-\(kind.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .transcript: return "Subtitles"
        case .artifact(let kind): return kind.displayName
        }
    }

    var systemImage: String {
        switch self {
        case .transcript: return "captions.bubble"
        case .artifact(let kind): return kind.systemImage
        }
    }
}
