import SwiftUI

@main
struct VoxApp: App {
    var body: some Scene {
        MenuBarExtra("Vox", systemImage: "text.bubble") {
            Text("Vox Translator")
                .padding()
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
