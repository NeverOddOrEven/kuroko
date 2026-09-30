import CoreGraphics

/// A hidden app's window that gets a tint of its own, ordered directly above it.
public struct OverlayTarget: Sendable, Equatable {
    public var windowID: CGWindowID
    public var ownerPID: pid_t
    public var appID: String
    /// Global display coordinates (top-left origin).
    public var bounds: CGRect
    public var layer: Int
    /// Carries the app's Reveal and Dismiss prompt.
    public var showsPrompt: Bool
}

public enum OverlayLayout {
    /// Normal and floating windows. Menus, popups and the Dock are left alone.
    public static let coveredLayers = 0...3
    /// Smaller windows (often invisible helpers) aren't tinted.
    public static let minimumSize = CGSize(width: 40, height: 40)
    /// The prompt goes on the app's frontmost window at least this big, if it has one.
    public static let promptSize = CGSize(width: 320, height: 140)

    /// Windows of hidden apps on `display`, front to back as `windows` lists them. Windows
    /// whose `appID` is nil (Kuroko's own, and processes without a bundle ID) are skipped.
    public static func targets(
        windows: [WindowSnapshot],
        display: CGRect,
        appID: (pid_t) -> String?,
        isHidden: (String) -> Bool
    ) -> [OverlayTarget] {
        var targets: [OverlayTarget] = windows.compactMap { window in
            let onDisplay = window.bounds.intersection(display)
            guard coveredLayers.contains(window.layer),
                  !onDisplay.isNull, onDisplay.width > 0, onDisplay.height > 0,
                  window.bounds.width >= minimumSize.width, window.bounds.height >= minimumSize.height,
                  let id = appID(window.ownerPID), isHidden(id)
            else { return nil }
            return OverlayTarget(
                windowID: window.windowID, ownerPID: window.ownerPID, appID: id,
                bounds: window.bounds, layer: window.layer, showsPrompt: false
            )
        }
        var prompted: Set<String> = []
        for fitsPrompt in [true, false] {
            for index in targets.indices where !prompted.contains(targets[index].appID) {
                let size = targets[index].bounds.size
                guard !fitsPrompt || (size.width >= promptSize.width && size.height >= promptSize.height) else { continue }
                targets[index].showsPrompt = true
                prompted.insert(targets[index].appID)
            }
        }
        return targets
    }
}
