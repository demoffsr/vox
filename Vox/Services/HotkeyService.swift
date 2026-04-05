import AppKit
import Carbon.HIToolbox

final class HotkeyService {
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onTrigger: () -> Void

    // Store callback pointer so Carbon can reach us
    private static var current: HotkeyService?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        print("[Vox] HotkeyService starting with Carbon API...")
        HotkeyService.current = self

        // Register Carbon event handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                HotkeyService.current?.handleHotKey()
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        print("[Vox] InstallEventHandler status: \(status)")

        // Register Cmd+T hotkey
        let hotkeyID = EventHotKeyID(
            signature: OSType(0x564F5821), // "VOX!"
            id: 1
        )

        let regStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(cmdKey),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        print("[Vox] RegisterEventHotKey status: \(regStatus) (0 = success)")
    }

    func stop() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        HotkeyService.current = nil
    }

    private func handleHotKey() {
        print("[Vox] Carbon hotkey triggered!")
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger()
        }
    }

    deinit {
        stop()
    }
}
