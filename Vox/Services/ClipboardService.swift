import AppKit

struct ClipboardService {
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
}
