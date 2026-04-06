import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    let subtitleService = SubtitleService()
    private var settingsWindow: NSWindow?
    private var subtitlePollingTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register this object as the Services provider
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Poll file-based IPC for subtitle activation flag
        subtitlePollingTask = Task {
            let controlFile = URL(fileURLWithPath: "/tmp/vox-control.json")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let active = Self.readControlFlag(from: controlFile)
                if active && !subtitleService.isRunning {
                    await subtitleService.start()
                } else if !active && subtitleService.isRunning {
                    await subtitleService.stop()
                }
            }
        }
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

    static func readControlFlag(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return dict["active"] as? Bool ?? false
    }

    static func writeControlFlag(_ active: Bool, to url: URL) {
        let dict: [String: Any] = ["active": active]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: url, options: .atomic)
        }
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
                    let controlFile = URL(fileURLWithPath: "/tmp/vox-control.json")
                    if appDelegate.subtitleService.isRunning {
                        AppDelegate.writeControlFlag(false, to: controlFile)
                        await appDelegate.subtitleService.stop()
                    } else {
                        AppDelegate.writeControlFlag(true, to: controlFile)
                        await appDelegate.subtitleService.start()
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
