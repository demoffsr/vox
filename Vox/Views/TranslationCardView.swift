import SwiftUI

/// Point-translation card. Matches the lecture translation window (TranslationStreamView)
/// exactly: title bar with language pill + close button, gradient divider, empty/loading/
/// content state, gradient divider, bottom bar with Copy.
///
/// When Smart Mode is enabled, adds a Look Up-style tab bar with Definition,
/// Examples, and Notes tabs alongside the standard Translation tab.
struct TranslationCardView: View {
    @Bindable var viewModel: TranslationViewModel
    @State private var copied = false
    @State private var showLanguagePicker = false
    @State private var hoveredLanguage: TargetLanguage?
    @State private var hoveredTab: LookUpTab?
    @State private var copiedImageID: UUID?

    private var smartModeEnabled: Bool { AppSettings.shared.smartModeEnabled }
    private var isAnyLoading: Bool { viewModel.isTranslating || viewModel.isLoadingLookUp || viewModel.isLoadingImages }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            GradientDivider()

            if showLanguagePicker {
                languagePickerInline
                GradientDivider()
            }

            if smartModeEnabled {
                lookUpTabBar
                if isAnyLoading {
                    ShimmerBar()
                } else {
                    GradientDivider()
                }
            }

            activeTabContent
            GradientDivider()
            bottomBar
        }
        .frame(width: 420)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: showLanguagePicker)
        .animation(.easeOut(duration: 0.2), value: viewModel.activeTab)
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

    // MARK: - Look Up Tab Bar  (matches HistoryTabBar styling)

    private var lookUpTabBar: some View {
        HStack(spacing: 2) {
            ForEach(viewModel.visibleTabs) { tab in
                lookUpTabButton(for: tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func lookUpTabButton(for tab: LookUpTab) -> some View {
        let isActive = tab == viewModel.activeTab
        return Button(action: { viewModel.activeTab = tab }) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
            }
            .foregroundStyle(isActive ? .white.opacity(0.9) : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: VoxTokens.Radius.xs, style: .continuous)
                    .fill(isActive
                          ? Color.white.opacity(0.12)
                          : (hoveredTab == tab ? Color.white.opacity(0.06) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hoveredTab = $0 ? tab : nil }
    }

    // MARK: - Active Tab Content

    @ViewBuilder
    private var activeTabContent: some View {
        if !smartModeEnabled || viewModel.activeTab == .translation {
            cardContent
        } else if viewModel.activeTab == .images {
            imagesContent
        } else if viewModel.isLoadingLookUp {
            SkeletonShimmer()
        } else if let data = viewModel.lookUpData {
            switch viewModel.activeTab {
            case .translation:
                cardContent
            case .dictionary:
                dictionaryContent(data.dictionary)
            case .context:
                contextContent(data.context)
            case .images:
                imagesContent
            }
        } else if let err = viewModel.lookUpError {
            emptyState(icon: "exclamationmark.circle", caption: err, tint: VoxTokens.Ink.subtle)
        } else {
            emptyState(icon: "text.bubble", caption: "No data available", tint: VoxTokens.Ink.faint)
        }
    }

    // MARK: - Translation Content  (existing, unchanged)

    @ViewBuilder
    private var cardContent: some View {
        if let error = viewModel.error {
            emptyState(icon: "exclamationmark.circle", caption: error, tint: VoxTokens.Ink.subtle)
        } else if viewModel.translatedText.isEmpty && viewModel.isTranslating {
            SkeletonShimmer()
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

    // MARK: - Dictionary Content

    @ViewBuilder
    private func dictionaryContent(_ dictionary: DictionaryData?) -> some View {
        if let dict = dictionary {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !viewModel.sourceText.isEmpty {
                        Text(viewModel.sourceText)
                            .font(VoxTokens.Typo.body)
                            .foregroundStyle(VoxTokens.Ink.muted)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 8) {
                        Text(dict.partOfSpeech.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(VoxTokens.Ink.subtle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(VoxTokens.Ink.trace))

                        if let pronunciation = dict.pronunciation {
                            Text(pronunciation)
                                .font(VoxTokens.Typo.mono)
                                .foregroundStyle(VoxTokens.Ink.muted)
                        }
                    }

                    ForEach(Array(dict.entries.enumerated()), id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(VoxTokens.Ink.subtle)
                                    .frame(width: 16, alignment: .trailing)
                                Text(entry.meaning)
                                    .font(VoxTokens.Typo.bodyLg)
                                    .foregroundStyle(VoxTokens.Ink.primary)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                            }

                            if let example = entry.example {
                                Text(example)
                                    .font(VoxTokens.Typo.body)
                                    .italic()
                                    .foregroundStyle(VoxTokens.Ink.subtle)
                                    .padding(.leading, 24)
                                    .textSelection(.enabled)
                            }

                            if let translation = entry.exampleTranslation {
                                Text(translation)
                                    .font(VoxTokens.Typo.body)
                                    .foregroundStyle(VoxTokens.Ink.muted)
                                    .padding(.leading, 24)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 260)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        } else {
            emptyState(icon: "character.book.closed", caption: "No dictionary data", tint: VoxTokens.Ink.faint)
        }
    }

    // MARK: - Context Content

    @ViewBuilder
    private func contextContent(_ context: ContextData?) -> some View {
        if let ctx = context {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Synonyms
                    if !ctx.synonyms.isEmpty {
                        contextSection("Synonyms") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(ctx.synonyms) { syn in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(syn.word)
                                            .font(VoxTokens.Typo.body)
                                            .foregroundStyle(VoxTokens.Ink.secondary)
                                            .textSelection(.enabled)
                                        Text(syn.note)
                                            .font(VoxTokens.Typo.tiny)
                                            .foregroundStyle(VoxTokens.Ink.muted)
                                            .italic()
                                    }
                                }
                            }
                        }
                    }

                    // Register
                    if let register = ctx.register {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(registerColor(register))
                                .frame(width: 7, height: 7)
                            Text(register.capitalized)
                                .font(VoxTokens.Typo.small)
                                .foregroundStyle(VoxTokens.Ink.tertiary)
                        }
                    }

                    // Collocations
                    if !ctx.collocations.isEmpty {
                        contextSection("Collocations") {
                            Text(ctx.collocations.joined(separator: " \u{00B7} "))
                                .font(VoxTokens.Typo.body)
                                .foregroundStyle(VoxTokens.Ink.muted)
                                .textSelection(.enabled)
                        }
                    }

                    // False friends
                    if !ctx.falseFriends.isEmpty {
                        contextSection("False friends", icon: "exclamationmark.triangle") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(ctx.falseFriends) { ff in
                                    HStack(spacing: 4) {
                                        Text(ff.word)
                                            .font(VoxTokens.Typo.body)
                                            .foregroundStyle(VoxTokens.Ink.secondary)
                                        Text("\u{2192}")
                                            .font(VoxTokens.Typo.body)
                                            .foregroundStyle(VoxTokens.Ink.subtle)
                                        Text(ff.meaning)
                                            .font(VoxTokens.Typo.body)
                                            .foregroundStyle(VoxTokens.Ink.muted)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }

                    // Notes
                    if !ctx.notes.isEmpty {
                        contextSection("Notes", icon: "lightbulb") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(ctx.notes, id: \.self) { note in
                                    Text(note)
                                        .font(VoxTokens.Typo.body)
                                        .foregroundStyle(VoxTokens.Ink.muted)
                                        .lineSpacing(3)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 260)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        } else {
            emptyState(icon: "text.magnifyingglass", caption: "No context data", tint: VoxTokens.Ink.faint)
        }
    }

    // MARK: - Images Content

    private let imageColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    @ViewBuilder
    private var imagesContent: some View {
        if viewModel.isLoadingImages {
            emptyState(icon: "photo", caption: "Searching images…", tint: VoxTokens.Ink.faint)
        } else if viewModel.imageData.isEmpty {
            emptyState(icon: "photo", caption: "No images found", tint: VoxTokens.Ink.faint)
        } else {
            ScrollView {
                LazyVGrid(columns: imageColumns, spacing: 8) {
                    ForEach(viewModel.imageData) { item in
                        imageTile(item)
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: 260)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func imageTile(_ item: ImageItem) -> some View {
        let isCopied = copiedImageID == item.id
        return Button(action: { copyImage(item) }) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: item.imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 90, maxHeight: 90)
                            .clipped()
                    case .failure:
                        Color(white: 0.15)
                            .frame(height: 90)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.system(size: 16))
                                    .foregroundStyle(VoxTokens.Ink.whisper)
                            }
                    default:
                        Color(white: 0.15)
                            .frame(height: 90)
                            .overlay {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                    }
                }

                // Gradient overlay + title
                LinearGradient(
                    colors: [.black.opacity(0.6), .clear],
                    startPoint: .bottom,
                    endPoint: .center
                )

                // Copy feedback or title
                HStack(spacing: 4) {
                    if isCopied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("Copied!")
                            .font(.system(size: 9, weight: .semibold))
                    } else {
                        Text(item.title)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white.opacity(isCopied ? 1 : 0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: VoxTokens.Radius.xs, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VoxTokens.Radius.xs, style: .continuous)
                    .strokeBorder(VoxTokens.Ink.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func copyImage(_ item: ImageItem) {
        let urlToCopy = item.fullImageURL ?? item.imageURL
        copiedImageID = item.id
        Task {
            let success = await ImageSearchService.copyImageToClipboard(from: urlToCopy)
            if !success {
                // Fallback: copy URL as string
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlToCopy.absoluteString, forType: .string)
            }
            try? await Task.sleep(for: .seconds(1.2))
            if copiedImageID == item.id {
                copiedImageID = nil
            }
        }
    }

    // MARK: - Context Helpers

    private func contextSection<Content: View>(
        _ title: String,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(VoxTokens.Ink.subtle)
                }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VoxTokens.Ink.subtle)
            }
            content()
        }
    }

    private func registerColor(_ register: String) -> Color {
        switch register.lowercased() {
        case "formal":   .blue
        case "informal": .orange
        case "slang":    .red
        default:         .green
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
                isDisabled: viewModel.copyableText.isEmpty,
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
            if viewModel.activeTab == .translation {
                viewModel.dismissPanel()
            }
        }
    }
}

// MARK: - Shimmer Bar

private struct ShimmerBar: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Rectangle()
                .fill(.white.opacity(0.06))
                .overlay {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white.opacity(0.25), location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: w * 0.35)
                        .offset(x: -w * 0.5 + phase * w * 1.5)
                }
                .clipped()
        }
        .frame(height: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - Skeleton Shimmer

private struct SkeletonShimmer: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            skeletonLine(width: 0.5)
            skeletonLine(width: 0.9)
            skeletonLine(width: 0.75)
            skeletonLine(width: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 30)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func skeletonLine(width fraction: CGFloat) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white.opacity(0.08), location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(x: -w + phase * w * 2)
                }
                .clipped()
                .frame(width: w * fraction)
        }
        .frame(height: 14)
    }
}
