import SwiftUI
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    let subtitleService = SubtitleService()
    private var settingsWindow: NSWindow?
    /// Installed speech recognition locales (loaded at launch).
    var installedLocales: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load installed speech locales for the Subtitle Language menu
        Task {
            let dictLocales = await DictationTranscriber.installedLocales
            let speechLocales = await SpeechTranscriber.installedLocales
            let allCodes = (dictLocales + speechLocales).compactMap { $0.language.languageCode?.identifier }
            self.installedLocales = Set(allCodes)
            print("[Vox] Installed speech locales — Dictation: \(dictLocales.map(\.identifier)), SpeechTranscriber: \(speechLocales.map(\.identifier))")
        }
        // Register this object as the Services provider
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Listen for start/stop subtitle commands from Safari extension
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleStartSubtitles),
            name: NSNotification.Name("com.vox.startSubtitles"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleStopSubtitles),
            name: NSNotification.Name("com.vox.stopSubtitles"), object: nil)
    }

    @objc private func handleStartSubtitles() {
        print("[Vox] Received startSubtitles notification")
        Task { await subtitleService.start() }
    }

    @objc private func handleStopSubtitles() {
        print("[Vox] Received stopSubtitles notification")
        Task { await subtitleService.stop() }
    }

    /// Called by macOS Services menu — "Translate with Vox"
    @objc func translateService(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text provided" as NSString
            return
        }
        coordinator.translateText(text)
    }

    func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vox Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

@main
struct VoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Vox", systemImage: "bubble.left.fill") {
            Button("Open Vox") {
                appDelegate.coordinator.showLastOrTranslate()
            }
            Button("Translate Selection") {
                appDelegate.coordinator.translate()
            }
            Divider()
            Button(appDelegate.subtitleService.isRunning ? "Stop Live Subtitles" : "Start Live Subtitles") {
                Task {
                    if appDelegate.subtitleService.isRunning {
                        await appDelegate.subtitleService.stop()
                    } else {
                        let settings = AppSettings.shared
                        appDelegate.subtitleService.subtitleLocale = settings.subtitleLanguage.locale
                        await appDelegate.subtitleService.start()
                    }
                }
            }
            Menu("Subtitle Language") {
                let currentLang = AppSettings.shared.subtitleLanguage
                let installed = appDelegate.installedLocales
                let availableLanguages = SubtitleLanguage.allCases.filter { lang in
                    installed.isEmpty || installed.contains(lang.languageCode)
                }
                ForEach(availableLanguages) { lang in
                    Button {
                        AppSettings.shared.subtitleLanguage = lang
                        appDelegate.subtitleService.subtitleLocale = lang.locale
                        if appDelegate.subtitleService.isRunning {
                            Task {
                                await appDelegate.subtitleService.stop()
                                await appDelegate.subtitleService.start()
                            }
                        }
                    } label: {
                        let check = lang == currentLang ? "✓ " : "   "
                        Text("\(check)\(lang.flag) \(lang.displayName)")
                    }
                }
                if availableLanguages.count < SubtitleLanguage.allCases.count {
                    Divider()
                    Button("Add more languages...") {
                        // Open Keyboard settings where Dictation languages are configured
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            Menu("Translate Subtitles") {
                Button("Off") {
                    AppSettings.shared.subtitleTranslationLanguage = nil
                }
                Divider()
                ForEach(TargetLanguage.allCases.filter { $0 != .auto }) { lang in
                    Button("\(lang.flag) \(lang.rawValue)") {
                        AppSettings.shared.subtitleTranslationLanguage = lang
                    }
                }
            }
            Divider()
            Button("Settings...") {
                appDelegate.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit Vox") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
