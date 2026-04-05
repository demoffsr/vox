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
}
