import SwiftUI

/// Point-translation card. Matches the lecture translation window (TranslationStreamView)
/// exactly: title bar with language pill + close button, gradient divider, empty/loading/
/// content state, gradient divider, bottom bar with Copy.
struct TranslationCardView: View {
    @Bindable var viewModel: TranslationViewModel
    @State private var copied = false
    @State private var showLanguagePicker = false
    @State private var hoveredLanguage: TargetLanguage?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            GradientDivider()

            if showLanguagePicker {
                languagePickerInline
                GradientDivider()
            }

            cardContent
            GradientDivider()
            bottomBar
        }
        .frame(width: 420)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: showLanguagePicker)
    }

    // MARK: - Title Bar  (mirrors TranslationStreamView.titleBar)

    private var titleBar: some View {
        HStack(spacing: 8) {
            Button(action: {
                withAnimation(.easeOut(duration: 0.2)) {
                    showLanguagePicker.toggle()
                }
            }) {
                HStack(spacing: 5) {
                    Text(viewModel.targetLanguage.flag)
                        .font(.system(size: 13))
                    Text(viewModel.targetLanguage == .auto ? "Auto" : viewModel.targetLanguage.rawValue)
                        .font(VoxTokens.Typo.small)
                        .foregroundStyle(.white.opacity(0.8))
                    Image(systemName: showLanguagePicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(showLanguagePicker ? 0.12 : 0.08)))
            }
            .buttonStyle(.plain)

            if viewModel.isTranslating {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                    Text("Translating")
                        .font(VoxTokens.Typo.tiny)
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            Spacer()

            VoxCircleIconButton(icon: "xmark") {
                viewModel.dismissPanel()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Inline Language Picker  (mirrors TranslationStreamView.languagePickerInline)

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
                            .foregroundStyle(VoxTokens.Ink.secondary)
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
                        RoundedRectangle(cornerRadius: VoxTokens.Radius.xs, style: .continuous)
                            .fill(hoveredLanguage == lang ? VoxTokens.Ink.hairline : .clear)
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
        .background(VoxTokens.Ink.floor)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Content  (empty / loading / error / translation — all in lecture's empty-state
    // layout: centered icon + caption for non-happy paths, ScrollView for the result)

    @ViewBuilder
    private var cardContent: some View {
        if let error = viewModel.error {
            emptyState(icon: "exclamationmark.circle", caption: error, tint: VoxTokens.Ink.subtle)
        } else if viewModel.translatedText.isEmpty && viewModel.isTranslating {
            emptyState(icon: "ellipsis.bubble", caption: "Translating…", tint: VoxTokens.Ink.faint)
        } else if viewModel.translatedText.isEmpty {
            emptyState(icon: "text.bubble", caption: "Waiting for text…", tint: VoxTokens.Ink.faint)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !viewModel.sourceText.isEmpty {
                        Text(viewModel.sourceText)
                            .font(.system(size: 13))
                            .foregroundStyle(VoxTokens.Ink.muted)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(viewModel.translatedText)
                        .font(VoxTokens.Typo.bodyLg)
                        .foregroundStyle(VoxTokens.Ink.primary)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(minHeight: 60, maxHeight: 260)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    /// Empty-state block mirroring TranslationStreamView.subtitlesContent empty branch.
    private func emptyState(icon: String, caption: String, tint: Color) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.12))
            Text(caption)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 50)
    }

    // MARK: - Bottom Bar  (mirrors TranslationStreamView.bottomBar, single Copy button)

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Spacer()

            VoxCapsuleButton(
                copied ? "Copied!" : "Copy",
                icon: copied ? "checkmark" : "doc.on.doc",
                isAccent: copied,
                isDisabled: viewModel.translatedText.isEmpty,
                action: copyAction
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func copyAction() {
        viewModel.copyTranslation()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
            viewModel.dismissPanel()
        }
    }
}
