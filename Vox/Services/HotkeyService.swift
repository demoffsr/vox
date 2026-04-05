import AppKit
import Carbon.HIToolbox

final class HotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.isHotkeyMatch(event) == true {
                self?.onTrigger()
                return nil
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if isHotkeyMatch(event) {
            DispatchQueue.main.async { [weak self] in
                self?.onTrigger()
            }
        }
    }

    private func isHotkeyMatch(_ event: NSEvent) -> Bool {
        let requiredFlags: NSEvent.ModifierFlags = [.command, .shift]
        let pressedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return pressedFlags == requiredFlags && event.keyCode == UInt16(kVK_ANSI_T)
    }

    deinit {
        stop()
    }
}
