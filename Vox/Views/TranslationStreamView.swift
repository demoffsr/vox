// Vox/Views/TranslationStreamView.swift
import SwiftUI

struct TranslationStreamView: View {
    @Bindable var viewModel: TranslationStreamViewModel
    @State private var copied = false
    @State private var polished = false
    @State private var showLanguagePicker = false
    @State private var hoveredLanguage: TargetLanguage?
    @State private var isNearBottom = true
    var onLanguageChanged: ((TargetLanguage) -> Void)?
    var onPolish: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            gradientDivider

            if showLanguagePicker {
                languagePickerInline
                gradientDivider
            }

            streamContent
            gradientDivider
            bottomBar
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: showLanguagePicker)
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            // Language picker pill
            Button(action: {
                withAnimation(.easeOut(duration: 0.2)) {
                    showLanguagePicker.toggle()
                }
            }) {
                HStack(spacing: 5) {
                    Text(viewModel.selectedLanguage.flag)
                        .font(.system(size: 13))
                    Text(viewModel.selectedLanguage.rawValue)
                        .font(.system(size: 12, weight: .medium))
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

            // Status indicator
            if viewModel.isActive {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .shadow(color: .green.opacity(0.5), radius: 3)
                    Text("Listening")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            Spacer()

            // Close button
            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Inline Language Picker

    private var languagePickerInline: some View {
        VStack(spacing: 1) {
            ForEach(TargetLanguage.allCases.filter { $0 != .auto }) { lang in
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showLanguagePicker = false
                    }
                    if lang != viewModel.selectedLanguage {
                        viewModel.selectedLanguage = lang
                        viewModel.clear()
                        onLanguageChanged?(lang)
                    }
                }) {
                    HStack(spacing: 8) {
                        Text(lang.flag)
                            .font(.system(size: 14))
                        Text(lang.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        if lang == viewModel.selectedLanguage {
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

    // MARK: - Stream Content

    private var streamContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if viewModel.accumulatedText.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.12))
                            Text("Waiting for speech...")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, 50)
                    } else {
                        styledText
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
            }
            .onChange(of: viewModel.accumulatedText) {
                if isNearBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
                return distanceFromBottom < 50
            } action: { _, newValue in
                isNearBottom = newValue
            }
        }
        .frame(minHeight: 100)
    }

    // MARK: - Styled Text (final = bright, draft = dim)

    private var styledText: Text {
        let full = viewModel.accumulatedText
        guard !full.isEmpty else { return Text("") }

        let safeLen = min(viewModel.finalLength, full.count)
        let finalPart = String(full.prefix(safeLen))
        let draftPart = String(full.dropFirst(safeLen))

        if draftPart.isEmpty {
            return Text(finalPart)
                .foregroundColor(.white.opacity(0.95))
        }

        return Text(finalPart)
            .foregroundColor(.white.opacity(0.95))
        + Text(draftPart)
            .foregroundColor(.white.opacity(0.35))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // Clear button
            Button(action: { viewModel.clear() }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Clear")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.accumulatedText.isEmpty)

            // Polish button
            Button(action: polishAction) {
                HStack(spacing: 6) {
                    if viewModel.isPolishing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: polished ? "checkmark" : "wand.and.stars")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(viewModel.isPolishing ? "Polishing..." : polished ? "Polished!" : "Polish")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(polished ? .green : .white.opacity(0.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(polished ? .green.opacity(0.15) : .white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.accumulatedText.isEmpty || viewModel.isPolishing)
            .animation(.easeInOut(duration: 0.2), value: polished)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isPolishing)

            Spacer()

            // Word count
            if !viewModel.accumulatedText.isEmpty {
                let wordCount = viewModel.accumulatedText.split(separator: " ").count
                Text("\(wordCount) words")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.2))
            }

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
                .background(Capsule().fill(copied ? .green.opacity(0.15) : .white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.accumulatedText.isEmpty)
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

    private func polishAction() {
        onPolish?()
        // Success animation is triggered from outside when polish completes;
        // observe isPolishing going from true → false
        Task {
            // Wait for polishing to start
            while !viewModel.isPolishing { try? await Task.sleep(for: .milliseconds(50)) }
            // Wait for polishing to finish
            while viewModel.isPolishing { try? await Task.sleep(for: .milliseconds(100)) }
            polished = true
            try? await Task.sleep(for: .seconds(1.5))
            polished = false
        }
    }

    private func copyAction() {
        viewModel.copyAll()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
