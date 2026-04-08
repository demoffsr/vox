import SwiftUI

struct TranslationCardView: View {
    @Bindable var viewModel: TranslationViewModel
    @State private var copied = false
    @State private var showLanguagePicker = false
    @State private var hoveredLanguage: TargetLanguage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Language bar at top
            languageBar

            // Inline language picker (expands when open)
            if showLanguagePicker {
                languagePickerInline
            }

            gradientDivider

            // Source text
            if !viewModel.sourceText.isEmpty {
                sourceSection
                gradientDivider
            }

            // Translation
            translationSection

            gradientDivider

            // Bottom: Copy button
            bottomBar
        }
        .frame(width: 380)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: showLanguagePicker)
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 8) {
            // Target language pill
            Button(action: {
                withAnimation(.easeOut(duration: 0.2)) {
                    showLanguagePicker.toggle()
                }
            }) {
                HStack(spacing: 5) {
                    Text(viewModel.targetLanguage.flag)
                        .font(.system(size: 13))
                    Text(viewModel.targetLanguage == .auto ? "Auto" : viewModel.targetLanguage.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Image(systemName: showLanguagePicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.white.opacity(showLanguagePicker ? 0.12 : 0.08))
                )
            }
            .buttonStyle(.plain)

            if viewModel.isTranslating {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.blue.opacity(0.7))
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Inline Language Picker

    private var languagePickerInline: some View {
        VStack(spacing: 1) {
            ForEach(TargetLanguage.allCases) { lang in
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showLanguagePicker = false
                    }
                    if lang != viewModel.targetLanguage {
                        viewModel.retranslate(to: lang)
                    }
                }) {
                    HStack(spacing: 8) {
                        Text(lang.flag)
                            .font(.system(size: 14))
                        Text(lang.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        if lang == viewModel.targetLanguage {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hoveredLanguage == lang ? .white.opacity(0.06) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    hoveredLanguage = isHovered ? lang : nil
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.02))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Source Text

    private var sourceSection: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(.blue.opacity(0.4))
                .frame(width: 2)
                .padding(.vertical, 4)

            Text(viewModel.sourceText)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.015))
    }

    // MARK: - Translation

    private var translationSection: some View {
        Group {
            if let error = viewModel.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange.opacity(0.9))
                    Text(error)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.9))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            } else if viewModel.translatedText.isEmpty && viewModel.isTranslating {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.blue.opacity(0.7))
                    Text("Translating...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    Text(viewModel.translatedText)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineSpacing(4)
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
        HStack {
            Spacer()

            Button(action: copyAction) {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text(copied ? "Copied!" : "Copy")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(copied ? .green : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(copied ? .green.opacity(0.15) : .white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.translatedText.isEmpty)
            .animation(.easeInOut(duration: 0.2), value: copied)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var gradientDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0), .white.opacity(0.06), .white.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }

    private func copyAction() {
        viewModel.copyTranslation()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
            viewModel.dismissPanel()
        }
    }
}
