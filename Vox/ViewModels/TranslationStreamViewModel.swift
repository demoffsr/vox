// Vox/ViewModels/TranslationStreamViewModel.swift
import SwiftUI

@Observable
@MainActor
final class TranslationStreamViewModel {
    var accumulatedText: String = ""
    var isActive: Bool = false
    var selectedLanguage: TargetLanguage = .russian

    func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if accumulatedText.isEmpty {
            accumulatedText = trimmed
        } else {
            accumulatedText += " " + trimmed
        }
    }

    func clear() {
        accumulatedText = ""
    }

    func copyAll() {
        guard !accumulatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accumulatedText, forType: .string)
    }
}
