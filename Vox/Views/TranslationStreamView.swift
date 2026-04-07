// Vox/Views/TranslationStreamView.swift
import SwiftUI

struct TranslationStreamView: View {
    @Bindable var viewModel: TranslationStreamViewModel
    @State private var copied = false
    @State private var showLanguagePicker = false
    @State private var isNearBottom = true
    var onLanguageChanged: ((TargetLanguage) -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            languageBar
            gradientDivider
            streamContent
            gradientDivider
            bottomBar
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 8) {
            Button(action: { showLanguagePicker.toggle() }) {
                HStack(spacing: 5) {
                    Text(viewModel.selectedLanguage.flag)
                        .font(.system(size: 12))
                    Text(viewModel.selectedLanguage.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showLanguagePicker, arrowEdge: .bottom) {
                languageList
            }

            if viewModel.isActive {
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
            ForEach(TargetLanguage.allCases.filter { $0 != .auto }) { lang in
                Button(action: {
                    showLanguagePicker = false
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
                            .foregroundStyle(.primary)
                        Spacer()
                        if lang == viewModel.selectedLanguage {
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

    // MARK: - Stream Content

    private var streamContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if viewModel.accumulatedText.isEmpty {
                        Text("Waiting for speech...")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        Text(viewModel.accumulatedText)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }

                    // Invisible anchor at bottom
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
            }
            .onChange(of: viewModel.accumulatedText) {
                if isNearBottom {
                    withAnimation(.easeOut(duration: 0.15)) {
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

    private func copyAction() {
        viewModel.copyAll()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
