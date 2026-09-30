import CoreGraphics

/// An on-screen window, as reported by the window server.
public struct WindowSnapshot: Sendable, Equatable {
    public var windowID: CGWindowID
    public var ownerPID: pid_t
    public var bounds: CGRect
    public var layer: Int

    public init(windowID: CGWindowID = 0, ownerPID: pid_t, bounds: CGRect, layer: Int) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
    }
}

public enum ShareDetection {
    /// While Teams shares a screen it draws a border overlay covering that whole display, above
    /// normal windows. There's no API for Teams' sharing state, so this overlay is the signal.
    public static func isSharing(display: CGRect, windows: [WindowSnapshot], sharerPIDs: Set<pid_t>) -> Bool {
        // The overlay animates in and out, so allow a few points either way.
        let slack: CGFloat = 8
        return windows.contains { window in
            sharerPIDs.contains(window.ownerPID)
                && window.layer > 0
                && display.insetBy(dx: -slack, dy: -slack).contains(window.bounds)
                && window.bounds.width >= display.width - slack
                && window.bounds.height >= display.height - slack
        }
    }
}

/// Reports the end of a share once it has stayed ended for `grace`, so a brief gap (such as
/// Teams redrawing its overlay) isn't mistaken for the user stopping.
public struct ShareEndDetector: Sendable {
    public let grace: Double
    private var hasShared = false
    private var lastSharedAt: Double = 0

    public init(grace: Double = 1) {
        self.grace = grace
    }

    /// Returns true once per share, when it has ended. `now` is in seconds.
    public mutating func update(isSharing: Bool, now: Double) -> Bool {
        if isSharing {
            hasShared = true
            lastSharedAt = now
            return false
        }
        guard hasShared, now - lastSharedAt >= grace else { return false }
        hasShared = false
        return true
    }

    public mutating func reset() {
        hasShared = false
    }
}
