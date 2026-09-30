import AppKit
import Carbon.HIToolbox

/// Sees ⌘-Tab app switches and mouse clicks before the system acts on them: the event tap holds
/// each event until its handler returns. Needs Accessibility permission; without it, `start`
/// does nothing.
@MainActor
final class InputWatcher {
    /// ⌘ was released after Tab was pressed with it held, so the app switcher is about to switch.
    var onAppSwitch: () -> Void = {}
    /// Location in global display coordinates (top-left origin).
    var onMouseDown: (CGPoint) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tabbedWithCommand = false

    func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            log.info("No Accessibility permission; tints may flash when switching apps")
            return
        }
        let events: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let watcher = Unmanaged<InputWatcher>.fromOpaque(userInfo).takeUnretainedValue()
                    MainActor.assumeIsolated { watcher.handle(type, event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Couldn't create the input event tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        tabbedWithCommand = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab), event.flags.contains(.maskCommand) {
                tabbedWithCommand = true
            }
        case .flagsChanged:
            if tabbedWithCommand, !event.flags.contains(.maskCommand) {
                tabbedWithCommand = false
                onAppSwitch()
            }
        case .leftMouseDown:
            onMouseDown(event.location)
        default:
            break
        }
    }
}
