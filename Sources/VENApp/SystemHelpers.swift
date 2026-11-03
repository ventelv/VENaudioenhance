import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// A global hot key that reports both press and release, so it can act as a hold-to-mute button.
/// Uses Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class HoldHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onChange: (Bool) -> Void

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        var carbonMods: UInt32 = 0
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }

        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let me = Unmanaged<HoldHotKey>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { me.onChange(pressed) }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let id = EventHotKeyID(signature: OSType(0x5645_4E43), id: 1) // 'VENC'
        RegisterEventHotKey(keyCode, carbonMods, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
