import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    let subtitleService = SubtitleService()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                ForEach(SubtitleLanguage.allCases) { lang in
                    Button("\(lang.flag) \(lang.displayName)") {
                        AppSettings.shared.subtitleLanguage = lang
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
