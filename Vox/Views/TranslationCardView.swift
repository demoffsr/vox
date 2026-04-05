import SwiftUI

struct TranslationCardView: View {
    @Bindable var viewModel: TranslationViewModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Source text (collapsible, subtle)
            if !viewModel.sourceText.isEmpty {
                sourceSection
            }

            // Divider with gradient
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.08), .white.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)

            // Translation result
            translationSection

            // Bottom bar
            bottomBar
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Source Text

    private var sourceSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(viewModel.sourceText)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(3)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Translation

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.error {
                // Error state
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange.opacity(0.9))
                    Text(error)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.9))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            } else if viewModel.translatedText.isEmpty && viewModel.isTranslating {
                // Loading state
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.6))
                    Text("Translating...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            } else {
                // Translation result
                ScrollView {
                    Text(viewModel.translatedText)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 30, maxHeight: 220)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Model badge
            Text(AppSettings.shared.selectedModel.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.06))
                )

            if viewModel.isTranslating {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white.opacity(0.4))
                    .padding(.leading, 8)
            }

            Spacer()

            // Copy button
            Button(action: copyAction) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    if copied {
                        Text("Copied")
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .foregroundStyle(copied ? .green : .white.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.white.opacity(copied ? 0.08 : 0.06))
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.translatedText.isEmpty)
            .animation(.easeInOut(duration: 0.2), value: copied)

            // Close button
            Button(action: { viewModel.dismissPanel() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .padding(.leading, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func copyAction() {
        viewModel.copyTranslation()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
