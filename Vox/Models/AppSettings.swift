import SwiftUI
import ServiceManagement

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    var selectedModel: ClaudeModel {
        get {
            let raw = UserDefaults.standard.string(forKey: "selectedModel") ?? Constants.defaultModel.rawValue
            return ClaudeModel(rawValue: raw) ?? Constants.defaultModel
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectedModel")
        }
    }

    var smartModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "smartModeEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "smartModeEnabled") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update launch at login: \(error)")
            }
        }
    }

    var subtitleLanguage: SubtitleLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: "subtitleLanguage") ?? SubtitleLanguage.english.rawValue
            return SubtitleLanguage(rawValue: raw) ?? .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "subtitleLanguage")
        }
    }

    var showNativeSubtitles: Bool {
        get { UserDefaults.standard.object(forKey: "showNativeSubtitles") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showNativeSubtitles") }
    }

    var subtitleTranslationModel: ClaudeModel {
        get {
            let raw = UserDefaults.standard.string(forKey: "subtitleTranslationModel") ?? ClaudeModel.sonnet.rawValue
            return ClaudeModel(rawValue: raw) ?? .sonnet
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "subtitleTranslationModel")
        }
    }

    /// Installed speech recognition locale codes (e.g. "en", "ru"). Updated at launch and on manual refresh.
    var installedLocales: Set<String> = []

    var subtitleTranslationLanguage: TargetLanguage? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "subtitleTranslationLanguage") else { return nil }
            return TargetLanguage(rawValue: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: "subtitleTranslationLanguage")
        }
    }

    var subtitleDisplayMode: SubtitleDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "subtitleDisplayMode") ?? SubtitleDisplayMode.lecture.rawValue
            return SubtitleDisplayMode(rawValue: raw) ?? .lecture
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "subtitleDisplayMode")
        }
    }

    /// User's native/primary translation target. Used by auto language detection on ⌘T —
    /// text is translated to this language unless it's already in it. Defaults to the system
    /// locale's language when it maps to a supported `TargetLanguage`, otherwise `.english`.
    var primaryTargetLanguage: TargetLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "primaryTargetLanguage"),
                  let value = TargetLanguage(rawValue: raw),
                  value != .auto
            else {
                return Self.defaultPrimaryTargetLanguage
            }
            return value
        }
        set {
            guard newValue != .auto else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: "primaryTargetLanguage")
        }
    }

    /// Fallback target used when the detected source language already matches the primary target.
    /// Defaults to `.english`, or `.russian` when the primary is already English.
    var secondaryTargetLanguage: TargetLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "secondaryTargetLanguage"),
                  let value = TargetLanguage(rawValue: raw),
                  value != .auto
            else {
                return Self.defaultSecondaryTargetLanguage(primary: primaryTargetLanguage)
            }
            return value
        }
        set {
            guard newValue != .auto else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: "secondaryTargetLanguage")
        }
    }

    private static var defaultPrimaryTargetLanguage: TargetLanguage {
        let systemCode = Locale.current.language.languageCode?.identifier
        switch systemCode {
        case "ru": return .russian
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "zh": return .chinese
        case "ja": return .japanese
        case "en": return .english
        default:   return .english
        }
    }

    private static func defaultSecondaryTargetLanguage(primary: TargetLanguage) -> TargetLanguage {
        primary == .english ? .russian : .english
    }
}
