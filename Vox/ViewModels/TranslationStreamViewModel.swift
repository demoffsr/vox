import SwiftUI

// MARK: - Tab & Processing Types

enum StreamTab: String, CaseIterable, Identifiable {
    case subtitles = "Subtitles"
    case polish = "Polish"
    case summary = "Summary"
    case studyNotes = "Study Notes"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .subtitles: return "captions.bubble"
        case .polish: return "wand.and.stars"
        case .summary: return "list.bullet"
        case .studyNotes: return "book"
        }
    }
}

enum ProcessingMode: String, CaseIterable, Identifiable {
    case polish = "Polish"
    case summarize = "Summarize"
    case studyMode = "Study Mode"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .polish: return "wand.and.stars"
        case .summarize: return "list.bullet"
        case .studyMode: return "book"
        }
    }

    var targetTab: StreamTab {
        switch self {
        case .polish: return .polish
        case .summarize: return .summary
        case .studyMode: return .studyNotes
        }
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class TranslationStreamViewModel {
    private var finalText: String = ""
    private var draftText: String = ""
    var isActive: Bool = false
    var selectedLanguage: TargetLanguage = .russian

    // Tab state
    var activeTab: StreamTab = .subtitles
    var tabOrder: [StreamTab] = [.subtitles]
    var tabBuffers: [StreamTab: String] = [:]
    var processingStates: [ProcessingMode: Bool] = [:]

    /// Full display text for the Subtitles tab: final prefix + draft suffix.
    var accumulatedText: String {
        if finalText.isEmpty && draftText.isEmpty { return "" }
        if finalText.isEmpty { return draftText }
        if draftText.isEmpty { return finalText }
        return finalText + " " + draftText
    }

    /// Character length of the final portion in accumulatedText.
    var finalLength: Int {
        if finalText.isEmpty { return 0 }
        if draftText.isEmpty { return finalText.count }
        return finalText.count + 1
    }

    /// Text to display for the currently active tab.
    var displayText: String {
        switch activeTab {
        case .subtitles:
            return accumulatedText
        case .polish, .summary, .studyNotes:
            return tabBuffers[activeTab] ?? ""
        }
    }

    var activeTabIsSubtitles: Bool { activeTab == .subtitles }

    /// Tabs in current order (managed for drag reordering).
    var availableTabs: [StreamTab] {
        tabOrder
    }

    var isAnyProcessing: Bool {
        processingStates.values.contains(true)
    }

    func isProcessing(for tab: StreamTab) -> Bool {
        switch tab {
        case .polish: return processingStates[.polish] ?? false
        case .summary: return processingStates[.summarize] ?? false
        case .studyNotes: return processingStates[.studyMode] ?? false
        case .subtitles: return false
        }
    }

    func isProcessing(mode: ProcessingMode) -> Bool {
        processingStates[mode] ?? false
    }

    func setProcessing(_ mode: ProcessingMode, _ value: Bool) {
        processingStates[mode] = value
    }

    func setTabContent(_ tab: StreamTab, text: String) {
        tabBuffers[tab] = text
        if !tabOrder.contains(tab) {
            tabOrder.append(tab)
        }
    }

    func dismissTab(_ tab: StreamTab) {
        guard tab != .subtitles else { return }
        tabBuffers.removeValue(forKey: tab)
        tabOrder.removeAll { $0 == tab }
        if activeTab == tab {
            activeTab = .subtitles
        }
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        tabOrder.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Subtitle Text Management

    func updateDraft(_ text: String) {
        draftText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commitFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if finalText.isEmpty {
            finalText = trimmed
        } else {
            finalText += " " + trimmed
        }
        draftText = ""
    }

    func clear() {
        finalText = ""
        draftText = ""
    }

    func copyAll() {
        let text = displayText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
