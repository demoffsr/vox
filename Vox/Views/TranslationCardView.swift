import SwiftUI

struct TranslationCardView: View {
    @Bindable var viewModel: TranslationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().background(Color.white.opacity(0.1))

            if !viewModel.sourceText.isEmpty {
                sourceSection
                Divider().background(Color.white.opacity(0.1))
            }

            translationSection
            Divider().background(Color.white.opacity(0.1))
            statusBar
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThickMaterial)
                .environment(\.colorScheme, .dark)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private var headerBar: some View {
        HStack {
            Button(action: { viewModel.dismissPanel() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Button(action: { viewModel.copyTranslation() }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.translatedText.isEmpty)
            .help("Copy translation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sourceSection: some View {
        ScrollView {
            Text(viewModel.sourceText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 80)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var translationSection: some View {
        ScrollView {
            if let error = viewModel.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if viewModel.translatedText.isEmpty && viewModel.isTranslating {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Text(viewModel.translatedText)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(minHeight: 40, maxHeight: 200)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack {
            if viewModel.isTranslating {
                ProgressView()
                    .controlSize(.mini)
                Text("Translating...")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(AppSettings.shared.selectedModel.displayName)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
