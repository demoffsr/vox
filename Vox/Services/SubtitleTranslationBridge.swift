import Foundation
import Translation

/// On-device translation using Apple's Translation framework.
/// Zero network, zero rate limits, ~50-200ms per translation.
@MainActor
final class SubtitleTranslationBridge {
    private var session: TranslationSession?
    private var currentSource: Locale.Language?
    private var currentTarget: Locale.Language?

    func configure(source: Locale.Language, target: Locale.Language) async throws {
        guard source != currentSource || target != currentTarget else { return }
        currentSource = source
        currentTarget = target
        session = try await TranslationSession(installedSource: source, target: target)
        print("[TranslationBridge] Session ready: \(source.minimalIdentifier) → \(target.minimalIdentifier)")
    }

    func translate(_ text: String) async throws -> String {
        guard let session else {
            throw NSError(domain: "SubtitleTranslation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No translation session"])
        }
        let response = try await session.translate(text)
        return response.targetText
    }

    func clear() {
        session = nil
        currentSource = nil
        currentTarget = nil
    }
}
