import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation
import KurokoCore

/// Owns the headless "Kuroko" virtual display. The display exists exactly as long as
/// the `CGVirtualDisplay` object is retained.
@MainActor
final class VirtualDisplayManager {
    static let displayName = "Kuroko"
    private static let vendorID: UInt32 = 0x4B52  // "KR"
    private static let productID: UInt32 = 0x0001

    private var display: CGVirtualDisplay?
    private var maxPixels: (width: Int, height: Int) = (0, 0)
    private var appliedSpec: DisplayModeSpec?
    private var lastParkedFor: [CGRect] = []

    var displayID: CGDirectDisplayID? { display?.displayID }

    /// Creates the display (or recreates it if the spec no longer fits) and selects a mode
    /// matching the source in both logical size and backing scale. A no-op when the display
    /// already has that mode: re-applying settings reconfigures the display, which apps that
    /// are sharing or listing it can observe.
    func ensureDisplay(matching spec: DisplayModeSpec) async throws {
        if display == nil || !spec.fits(maxPixelWidth: maxPixels.width, maxPixelHeight: maxPixels.height) {
            try create(fitting: spec)
        }
        guard let display else { return }
        if spec == appliedSpec, let current = CGDisplayCopyDisplayMode(display.displayID), Self.mode(current, matches: spec) {
            return
        }
        log.info("Applying virtual display settings for \(String(describing: spec), privacy: .public)")
        guard display.apply(Self.settings(for: spec)) else {
            throw KurokoError.virtualDisplay("applySettings rejected \(spec)")
        }
        appliedSpec = spec
        if await !selectMode(matching: spec, on: display.displayID) {
            log.error("Virtual display has no mode matching \(String(describing: spec), privacy: .public); using default")
        }
    }

    /// Parks the display diagonally off the physical displays so the cursor rarely reaches it.
    /// Skips the work when the physical layout hasn't changed, because macOS may snap the
    /// requested origin and re-parking would loop on the resulting reconfiguration.
    func park(physicalDisplayBounds bounds: [CGRect]) {
        guard let id = displayID, bounds != lastParkedFor else { return }
        lastParkedFor = bounds
        let origin = DisplayGeometry.parkingOrigin(physicalDisplayBounds: bounds)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        log.info("Parked virtual display at \(origin.debugDescription, privacy: .public): \(result.rawValue)")
    }

    func destroy() {
        display = nil
        appliedSpec = nil
        lastParkedFor = []
    }

    private func create(fitting spec: DisplayModeSpec) throws {
        display = nil
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = Self.displayName
        descriptor.queue = .main
        descriptor.maxPixelsWide = UInt32(spec.pixelWidth)
        descriptor.maxPixelsHigh = UInt32(spec.pixelHeight)
        descriptor.sizeInMillimeters = DisplayGeometry.sizeInMillimeters(for: spec)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID
        descriptor.serialNum = 1
        descriptor.terminationHandler = { _, reason in
            log.error("Virtual display terminated: \(String(describing: reason), privacy: .public)")
        }
        guard let created = CGVirtualDisplay(descriptor: descriptor) else {
            throw KurokoError.virtualDisplay("CGVirtualDisplay init failed")
        }
        display = created
        maxPixels = (spec.pixelWidth, spec.pixelHeight)
        appliedSpec = nil
        lastParkedFor = []
        log.info("Created virtual display \(created.displayID, privacy: .public)")
    }

    private static func settings(for spec: DisplayModeSpec) -> CGVirtualDisplaySettings {
        let rate = spec.effectiveRefreshRate
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = spec.isHiDPI ? 1 : 0
        settings.modes = spec.virtualModeSizes.map {
            CGVirtualDisplayMode(width: UInt32($0.width), height: UInt32($0.height), refreshRate: rate)
        }
        return settings
    }

    /// Modes appear asynchronously after applySettings, so poll briefly.
    private func selectMode(matching spec: DisplayModeSpec, on id: CGDirectDisplayID) async -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        for _ in 0..<30 {
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            if let mode = modes.first(where: { Self.mode($0, matches: spec) }) {
                if let current = CGDisplayCopyDisplayMode(id), Self.mode(current, matches: spec) { return true }
                var config: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&config) == .success else { return false }
                CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
                return CGCompleteDisplayConfiguration(config, .forSession) == .success
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let available = ((CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? [])
            .map { "\($0.width)x\($0.height)@\($0.pixelWidth)x\($0.pixelHeight)" }
        log.error("Available virtual modes: \(available.joined(separator: ", "), privacy: .public)")
        return false
    }

    private static func mode(_ mode: CGDisplayMode, matches spec: DisplayModeSpec) -> Bool {
        spec.matches(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight)
    }
}
