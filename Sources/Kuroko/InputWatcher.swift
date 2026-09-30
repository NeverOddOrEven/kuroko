import AppKit
import Carbon.HIToolbox

/// Sees ⌘-Tab app switches and mouse clicks before the system acts on them: the event tap holds
/// each event until its handler returns. Needs Accessibility permission; without it, `start`
/// does nothing.
@MainActor
final class InputWatcher {
    /// ⌘ was released after Tab was pressed with it held, so the app switcher is about to switch
    /// to this app (nil if the switcher's selection couldn't be read).
    var onAppSwitch: (NSRunningApplication?) -> Void = { _ in }
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
                // The tap holds this release, so the switcher is still up with its selection.
                onAppSwitch(AppSwitcher.selectedApp())
            }
        case .leftMouseDown:
            onMouseDown(event.location)
        default:
            break
        }
    }
}

/// Reads the ⌘-Tab switcher and the Dock through the Dock's accessibility tree.
@MainActor
enum AppSwitcher {
    /// The app highlighted in the ⌘-Tab switcher, while it's showing.
    static func selectedApp() -> NSRunningApplication? {
        guard let dock = dockElement() else { return nil }
        let list = children(of: dock).first { string($0, kAXSubroleAttribute) == "AXProcessSwitcherList" }
        guard let list, let selected = (value(list, kAXSelectedChildrenAttribute) as? [AXUIElement])?.first else { return nil }
        return app(for: selected)
    }

    /// The running app whose Dock icon is at `point` (global, top-left origin), if any.
    static func dockApp(at point: CGPoint) -> NSRunningApplication? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element
        else { return nil }
        return app(for: element)
    }

    private static func dockElement() -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    /// Matches by bundle URL when the item has one, else by the app's name.
    private static func app(for item: AXUIElement) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let url = value(item, kAXURLAttribute) as? URL {
            return apps.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        }
        guard let title = string(item, kAXTitleAttribute), !title.isEmpty else { return nil }
        return apps.first { $0.localizedName == title }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }
}
