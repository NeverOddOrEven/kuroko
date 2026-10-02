import AppKit
import Carbon.HIToolbox

/// Sees ⌘-Tab app switches and mouse clicks before the system acts on them: the event tap holds
/// each event until its handler returns. The tap runs on its own thread, so ordinary key presses
/// never wait for Kuroko's main thread; only the events Kuroko acts on do. Needs Accessibility
/// permission; without it, `start` does nothing.
final class InputWatcher: @unchecked Sendable {
    /// ⌘ was released after Tab was pressed with it held, so the app switcher is about to switch
    /// to this app (nil if the switcher's selection couldn't be read). Set before `start`.
    var onAppSwitch: @MainActor (NSRunningApplication?) -> Void = { _ in }
    /// Location in global display coordinates (top-left origin). Set before `start`.
    var onMouseDown: @MainActor (CGPoint) -> Void = { _ in }

    /// The tap thread's run loop, while running. Written on the tap thread before `start`
    /// returns, and cleared by `stop`, both of which run on the main thread.
    private var runLoop: CFRunLoop?
    // Used only on the tap thread.
    private var tap: CFMachPort?
    private var tabbedWithCommand = false

    @MainActor
    func start() {
        guard runLoop == nil else { return }
        guard AXIsProcessTrusted() else {
            log.info("No Accessibility permission; tints may flash when switching apps")
            return
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            defer { ready.signal() }
            guard installTap() else { return }
            runLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.neveroddoreven.kuroko.input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    @MainActor
    func stop() {
        guard let runLoop else { return }
        self.runLoop = nil
        // @Sendable, or the block would inherit stop()'s main-actor isolation and trap when it
        // runs on the tap thread.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { @Sendable [self] in
            removeTap()
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// On the tap thread.
    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tabbedWithCommand = false
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    /// On the tap thread.
    private func installTap() -> Bool {
        let events: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<InputWatcher>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Couldn't create the input event tap")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// On the tap thread, while the event is held.
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
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { onAppSwitch(AppSwitcher.selectedApp()) }
                }
            }
        case .leftMouseDown:
            let location = event.location
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { onMouseDown(location) }
            }
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

    /// Looks the app up by the bundle ID behind the item's URL when it has one, which avoids
    /// reading every running app's details; else by the app's name.
    private static func app(for item: AXUIElement) -> NSRunningApplication? {
        if let url = value(item, kAXURLAttribute) as? URL, let bundleID = Bundle(url: url)?.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        guard let title = string(item, kAXTitleAttribute), !title.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == title && $0.activationPolicy == .regular }
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
