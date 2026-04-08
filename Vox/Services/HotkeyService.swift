import AppKit
import Carbon.HIToolbox

final class HotkeyService {
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var callbacks: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    private static var current: HotkeyService?

    init() {}

    func start() {
        print("[Vox] HotkeyService starting with Carbon API...")
        HotkeyService.current = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                guard result == noErr else { return result }
                HotkeyService.current?.handleHotKey(id: hotkeyID.id)
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        print("[Vox] InstallEventHandler status: \(status)")
    }

    /// Register a global hotkey. Returns the hotkey ID for later unregistration.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        callbacks[id] = handler

        let hotkeyID = EventHotKeyID(
            signature: OSType(0x564F5821), // "VOX!"
            id: id
        )

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        print("[Vox] RegisterEventHotKey id=\(id) status: \(status)")

        if let ref {
            hotkeyRefs[id] = ref
        }

        return id
    }

    func stop() {
        for (_, ref) in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()
        callbacks.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        HotkeyService.current = nil
    }

    private func handleHotKey(id: UInt32) {
        print("[Vox] Carbon hotkey triggered! id=\(id)")
        guard let callback = callbacks[id] else { return }
        DispatchQueue.main.async {
            callback()
        }
    }

    deinit {
        stop()
    }
}
