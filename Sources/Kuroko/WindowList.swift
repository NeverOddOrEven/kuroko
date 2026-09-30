import CoreGraphics
import Foundation
import KurokoCore

enum WindowList {
    /// On-screen windows, front to back, in global display coordinates (top-left origin).
    static func onScreen() -> [WindowSnapshot] {
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
