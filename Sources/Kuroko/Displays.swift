import AppKit
import CoreGraphics
import KurokoCore

/// Helpers for enumerating and describing displays.
enum Displays {
    /// Active displays other than Kuroko's. Other apps' virtual displays (DeskPad and the like)
    /// count as physical: to the user they're screens like any other.
    static func physicalDisplayIDs(excluding virtualID: CGDirectDisplayID?) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { $0 != virtualID }
    }

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    @MainActor
    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    @MainActor
    static func name(for id: CGDirectDisplayID) -> String {
        screen(for: id)?.localizedName ?? "Display \(id)"
    }

    static func modeSpec(for id: CGDirectDisplayID) -> DisplayModeSpec? {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return DisplayModeSpec(
            pointWidth: mode.width,
            pointHeight: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate
        )
    }
}
