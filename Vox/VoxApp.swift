import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register this object as the Services provider
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
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
