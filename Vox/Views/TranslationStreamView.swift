// Vox/Views/TranslationStreamView.swift
import SwiftUI
import UniformTypeIdentifiers

struct TranslationStreamView: View {
    @Bindable var viewModel: TranslationStreamViewModel
    @State private var copied = false
    @State private var showLanguagePicker = false
    @State private var hoveredLanguage: TargetLanguage?
    @State private var hoveredTab: StreamTab?
    @State private var draggingTab: StreamTab?
    @State private var isNearBottom = true
    var onLanguageChanged: ((TargetLanguage) -> Void)?
    var onCustomize: ((ProcessingMode) -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            gradientDivider

            if showLanguagePicker {
                languagePickerInline
                gradientDivider
            }

            if viewModel.availableTabs.count > 1 {
                tabBar
                gradientDivider
            }

            streamContent
            gradientDivider
            bottomBar
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: showLanguagePicker)
        .animation(.easeOut(duration: 0.2), value: viewModel.availableTabs.count)
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 8) {
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

    // MARK: - Tab Bar (draggable)

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(viewModel.availableTabs) { tab in
                    tabButton(for: tab)
                        .onDrag {
                            draggingTab = tab
                            return NSItemProvider(object: tab.rawValue as NSString)
                        }
                        .onDrop(of: [.text], delegate: TabDropDelegate(
                            tab: tab,
                            viewModel: viewModel,
                            draggingTab: $draggingTab
                        ))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func tabButton(for tab: StreamTab) -> some View {
        let isActive = viewModel.activeTab == tab
        let isProcessing = viewModel.isProcessing(for: tab)
        let isDragging = draggingTab == tab

        return Button(action: { viewModel.activeTab = tab }) {
            HStack(spacing: 5) {
                if isProcessing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: tab.icon)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))

                if tab != .subtitles && !isProcessing {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.25))
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.dismissTab(tab)
                            }
                        }
                }
            }
            .foregroundStyle(isActive ? .white.opacity(0.9) : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? .white.opacity(0.12) : hoveredTab == tab ? .white.opacity(0.06) : .clear)
            )
            .opacity(isDragging ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredTab = isHovered ? tab : nil
        }
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
                    if viewModel.activeTabIsSubtitles {
                        subtitlesContent
                    } else {
                        processedContent
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
            }
            .onChange(of: viewModel.accumulatedText) {
                if isNearBottom && viewModel.activeTabIsSubtitles {
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

    @ViewBuilder
    private var subtitlesContent: some View {
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
    }

    @ViewBuilder
    private var processedContent: some View {
        let text = viewModel.displayText
        if text.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Processing...")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 50)
        } else {
            MarkdownTextView(text: text)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
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

            customizeButton

            Spacer()

            if !viewModel.displayText.isEmpty {
                let wordCount = viewModel.displayText.split(separator: " ").count
                Text("\(wordCount) words")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.2))
            }

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
            .disabled(viewModel.displayText.isEmpty)
            .animation(.easeInOut(duration: 0.2), value: copied)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var customizeButton: some View {
        Menu {
            ForEach(ProcessingMode.allCases) { mode in
                Button(action: { onCustomize?(mode) }) {
                    Label {
                        Text(viewModel.isProcessing(mode: mode) ? "\(mode.rawValue)..." : mode.rawValue)
                    } icon: {
                        Image(systemName: mode.icon)
                    }
                }
                .disabled(viewModel.accumulatedText.isEmpty || viewModel.isProcessing(mode: mode))
            }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isAnyProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(viewModel.isAnyProcessing ? "Processing..." : "Customize")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.accumulatedText.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAnyProcessing)
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

// MARK: - Tab Drag & Drop

struct TabDropDelegate: DropDelegate {
    let tab: StreamTab
    let viewModel: TranslationStreamViewModel
    @Binding var draggingTab: StreamTab?

    func performDrop(info: DropInfo) -> Bool {
        draggingTab = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingTab, dragging != tab else { return }
        guard let fromIndex = viewModel.tabOrder.firstIndex(of: dragging),
              let toIndex = viewModel.tabOrder.firstIndex(of: tab) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.tabOrder.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Markdown Text Renderer

struct MarkdownTextView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private enum Block {
        case h1(String)
        case h2(String)
        case h3(String)
        case bullet(String)
        case blank
        case paragraph(String)
    }

    private func parseBlocks() -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blocks.append(.blank)
            } else if trimmed.hasPrefix("### ") {
                blocks.append(.h3(String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.h2(String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.h1(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("* ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(.bullet(content))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        return blocks
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .h1(let text):
            inlineMarkdown(text)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.top, 8)
                .padding(.bottom, 2)
        case .h2(let text):
            inlineMarkdown(text)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 6)
                .padding(.bottom, 1)
        case .h3(let text):
            inlineMarkdown(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                inlineMarkdown(text)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineSpacing(4)
            }
            .padding(.leading, 4)
        case .blank:
            Spacer()
                .frame(height: 8)
        case .paragraph(let text):
            inlineMarkdown(text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(4)
        }
    }

    private func inlineMarkdown(_ string: String) -> Text {
        // Parse **bold** and *italic* markers
        var result = Text("")
        var remaining = string[...]

        while !remaining.isEmpty {
            if remaining.hasPrefix("**") {
                remaining = remaining.dropFirst(2)
                if let endRange = remaining.range(of: "**") {
                    let bold = String(remaining[..<endRange.lowerBound])
                    result = result + Text(bold).bold()
                    remaining = remaining[endRange.upperBound...]
                } else {
                    result = result + Text("**")
                }
            } else if remaining.hasPrefix("*") {
                remaining = remaining.dropFirst(1)
                if let endRange = remaining.range(of: "*") {
                    let italic = String(remaining[..<endRange.lowerBound])
                    result = result + Text(italic).italic()
                    remaining = remaining[endRange.upperBound...]
                } else {
                    result = result + Text("*")
                }
            } else {
                // Consume until next markdown marker or end
                var plain = ""
                while !remaining.isEmpty && !remaining.hasPrefix("*") {
                    plain.append(remaining.removeFirst())
                }
                result = result + Text(plain)
            }
        }

        return result
    }
}
