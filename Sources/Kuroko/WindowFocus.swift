import AppKit
import ApplicationServices

enum WindowFocus {
    /// Brings another app's window to the front and activates the app. Uses the Accessibility
    /// API when Kuroko has it, since macOS may ignore activation requests from an app that
    /// isn't active itself.
    @MainActor
    static func raise(pid: pid_t, bounds: CGRect) {
        guard AXIsProcessTrusted() else {
            NSRunningApplication(processIdentifier: pid)?.activate()
            return
        }
        let app = AXUIElementCreateApplication(pid)
        if let window = window(of: app, matching: bounds) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Accessibility windows carry no window-server ID, so match on position and size, which
    /// share the window server's top-left coordinates.
    private static func window(of app: AXUIElement, matching bounds: CGRect) -> AXUIElement? {
        var windows: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success else { return nil }
        return (windows as? [AXUIElement])?.first { window in
            guard let frame = frame(of: window) else { return false }
            return abs(frame.minX - bounds.minX) <= 1 && abs(frame.minY - bounds.minY) <= 1
                && abs(frame.width - bounds.width) <= 1 && abs(frame.height - bounds.height) <= 1
        }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
