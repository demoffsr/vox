import AppKit
import Carbon.HIToolbox

struct ClipboardService {
    /// Simulate Cmd+C to copy selected text, then read clipboard
    func copySelectionAndRead() async -> String? {
        // Remember current clipboard content to detect change
        let changeCount = NSPasteboard.general.changeCount

        // Simulate Cmd+C
        simulateCopy()

        // Wait for clipboard to update
        try? await Task.sleep(for: .milliseconds(100))

        // Check if clipboard actually changed (means something was selected)
        if NSPasteboard.general.changeCount == changeCount {
            // Clipboard didn't change — nothing was selected, read whatever is there
        }

        return readText()
    }

    func readText() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if text.count > Constants.maxClipboardLength {
            return String(text.prefix(Constants.maxClipboardLength))
        }
        return text
    }

    private func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd+C
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up: Cmd+C
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
