import SwiftUI

struct TranslationCardView: View {
    @Bindable var viewModel: TranslationViewModel
    @State private var copied = false
    @State private var showLanguagePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Language bar at top
            languageBar

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
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 8) {
            // Target language pill
            Button(action: { showLanguagePicker.toggle() }) {
                HStack(spacing: 5) {
                    Text(viewModel.targetLanguage.flag)
                        .font(.system(size: 12))
                    Text(viewModel.targetLanguage == .auto ? "Auto" : viewModel.targetLanguage.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showLanguagePicker, arrowEdge: .bottom) {
                languageList
            }

            if viewModel.isTranslating {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white.opacity(0.4))
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var languageList: some View {
        VStack(spacing: 2) {
            ForEach(TargetLanguage.allCases) { lang in
                Button(action: {
                    showLanguagePicker = false
                    if lang != viewModel.targetLanguage {
                        viewModel.retranslate(to: lang)
                    }
                }) {
                    HStack(spacing: 8) {
                        Text(lang.flag)
                            .font(.system(size: 14))
                        Text(lang.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        if lang == viewModel.targetLanguage {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 180)
    }

    // MARK: - Source Text

    private var sourceSection: some View {
        Text(viewModel.sourceText)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
                        .tint(.white.opacity(0.6))
                    Text("Translating...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    Text(viewModel.translatedText)
                        .font(.system(size: 14))
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
        HStack {
            Spacer()

            // Copy button
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
        // Auto-dismiss after copy
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
            viewModel.dismissPanel()
        }
    }
}
