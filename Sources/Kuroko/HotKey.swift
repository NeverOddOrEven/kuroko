import Carbon.HIToolbox

/// A system-wide hotkey via Carbon, which needs no Accessibility permission.
@MainActor
final class HotKey {
    private static var nextID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: EventHotKeyID
    private let action: () -> Void

    /// Defaults to ⌃⌥⌘P.
    init(keyCode: Int = kVK_ANSI_P, modifiers: Int = controlKey | optionKey | cmdKey, action: @escaping () -> Void) {
        self.action = action
        id = EventHotKeyID(signature: OSType(0x4B52_4B4F), id: Self.nextID)  // "KRKO"
        Self.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                // Every hotkey's handler sees every press; pass on the ones registered by another.
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
                )
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard status == noErr, pressed.id == hotKey.id.id else { return OSStatus(eventNotHandledErr) }
                    hotKey.action()
                    return noErr
                }
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard status == noErr else {
            log.error("InstallEventHandler failed: \(status, privacy: .public)")
            return
        }

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
