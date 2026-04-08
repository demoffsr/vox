import SwiftUI
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    let subtitleService = SubtitleService()
    private var settingsWindow: NSWindow?
    /// Re-check installed speech locales and store in AppSettings.
    func refreshInstalledLocales() async {
        let dictLocales = await DictationTranscriber.installedLocales
        let speechLocales = await SpeechTranscriber.installedLocales
        let allCodes = (dictLocales + speechLocales).compactMap { $0.language.languageCode?.identifier }
        AppSettings.shared.installedLocales = Set(allCodes)
        print("[Vox] Installed speech locales — Dictation: \(dictLocales.map(\.identifier)), SpeechTranscriber: \(speechLocales.map(\.identifier))")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.subtitleService = subtitleService

        Task { await refreshInstalledLocales() }
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
            MenuPopoverView(
                coordinator: appDelegate.coordinator,
                subtitleService: appDelegate.subtitleService,
                refreshLocales: { [self] in await appDelegate.refreshInstalledLocales() },
                openSettings: { [self] in appDelegate.openSettings() }
            )
        }
        .menuBarExtraStyle(.window)
    }
}
