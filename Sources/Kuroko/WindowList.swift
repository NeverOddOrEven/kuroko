import CoreGraphics
import Foundation
import KurokoCore

@MainActor
enum WindowList {
    private static var cached: (windows: [WindowSnapshot], at: ContinuousClock.Instant)?

    /// On-screen windows, front to back, in global display coordinates (top-left origin).
    /// Listing them costs ~2 ms, so callers that tolerate `maxAge` share the latest list.
    static func onScreen(maxAge: Duration = .zero) -> [WindowSnapshot] {
        if let cached, ContinuousClock.now - cached.at <= maxAge { return cached.windows }
        let windows = fetch()
        cached = (windows, .now)
        return windows
    }

    private static func fetch() -> [WindowSnapshot] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { window in
            guard let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return WindowSnapshot(windowID: id, ownerPID: pid, bounds: bounds, layer: layer)
        }
    }
}
