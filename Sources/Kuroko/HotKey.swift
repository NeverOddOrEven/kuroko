import Carbon.HIToolbox

/// A system-wide hotkey via Carbon, which needs no Accessibility permission.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Defaults to ⌃⌥⌘P.
    init(keyCode: Int = kVK_ANSI_P, modifiers: Int = controlKey | optionKey | cmdKey, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard status == noErr else {
            log.error("InstallEventHandler failed: \(status, privacy: .public)")
            return
        }

        let id = EventHotKeyID(signature: OSType(0x4B52_4B4F), id: 1)  // "KRKO"
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if registered != noErr {
            log.error("RegisterEventHotKey failed: \(registered, privacy: .public)")
        }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
