import AppKit
import KurokoCore

/// Keeps the cursor off the virtual display by warping it back to the nearest physical display.
@MainActor
final class CursorGuard {
    private var monitors: [Any] = []
    private let virtualBounds: () -> CGRect?
    private let physicalBounds: () -> [CGRect]

    init(virtualBounds: @escaping () -> CGRect?, physicalBounds: @escaping () -> [CGRect]) {
        self.virtualBounds = virtualBounds
        self.physicalBounds = physicalBounds
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.check() }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func check() {
        // CGEvent locations use global display coordinates (top-left origin), same as CGDisplayBounds.
        guard let location = CGEvent(source: nil)?.location,
              let virtualBounds = virtualBounds(), virtualBounds.contains(location),
              let target = DisplayGeometry.nearestPoint(to: location, in: physicalBounds())
        else { return }
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1)  // avoid the post-warp input freeze
    }
}
