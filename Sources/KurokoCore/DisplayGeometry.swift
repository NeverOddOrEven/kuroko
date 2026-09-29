import CoreGraphics

/// A display mode described in both logical points and backing pixels.
public struct DisplayModeSpec: Sendable, Equatable {
    public var pointWidth: Int
    public var pointHeight: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double

    public init(pointWidth: Int, pointHeight: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    public var isHiDPI: Bool { pixelWidth > pointWidth }

    public func fits(maxPixelWidth: Int, maxPixelHeight: Int) -> Bool {
        pixelWidth <= maxPixelWidth && pixelHeight <= maxPixelHeight
    }

    public func matches(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) -> Bool {
        width == pointWidth && height == pointHeight && pixelWidth == self.pixelWidth && pixelHeight == self.pixelHeight
    }

    /// Mode sizes to offer the virtual display: the pixel size, plus the point size when HiDPI.
    /// Which of the two the API treats as the HiDPI base varies, so offer both and select
    /// whichever produced an exact match.
    public var virtualModeSizes: [CGSize] {
        let pixels = CGSize(width: pixelWidth, height: pixelHeight)
        return isHiDPI ? [pixels, CGSize(width: pointWidth, height: pointHeight)] : [pixels]
    }

    /// Refresh rate to advertise on the virtual display. Built-in panels report 0 (ProMotion/variable).
    public var effectiveRefreshRate: Double { refreshRate > 0 ? refreshRate : 60 }
}

public enum DisplayGeometry {
    /// Physical size to advertise for the virtual display. macOS derives the default
    /// scaling from pixel density, so claim a Retina-like ~220 ppi (or ~110 ppi at 1x).
    public static func sizeInMillimeters(for spec: DisplayModeSpec) -> CGSize {
        let pixelsPerInch: Double = spec.isHiDPI ? 220 : 110
        let mmPerInch = 25.4
        return CGSize(
            width: Double(spec.pixelWidth) / pixelsPerInch * mmPerInch,
            height: Double(spec.pixelHeight) / pixelsPerInch * mmPerInch
        )
    }

    /// Top-left origin (global CG coordinates, y down) that parks the virtual display
    /// diagonally off the bottom-right corner of all physical displays, touching only at a corner.
    public static func parkingOrigin(physicalDisplayBounds: [CGRect]) -> CGPoint {
        let union = physicalDisplayBounds.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return .zero }
        return CGPoint(x: union.maxX, y: union.maxY)
    }

    /// Displays whose mirroring must be turned off to take the virtual display out of any mirror
    /// set: the virtual display itself if it mirrors another, and every display mirroring it.
    /// `displays` pairs each online display with the display it mirrors (`kCGNullDirectDisplay` if none).
    public static func displaysToUnmirror(
        virtualID: CGDirectDisplayID,
        displays: [(id: CGDirectDisplayID, mirrors: CGDirectDisplayID)]
    ) -> [CGDirectDisplayID] {
        displays
            .filter { $0.mirrors != kCGNullDirectDisplay && ($0.id == virtualID || $0.mirrors == virtualID) }
            .map(\.id)
    }

    /// The closest point to `point` that lies inside one of `rects`. Used to warp the cursor
    /// back onto a physical display when it strays onto the virtual one.
    public static func nearestPoint(to point: CGPoint, in rects: [CGRect]) -> CGPoint? {
        rects
            .filter { !$0.isEmpty }
            .map { clamp(point, into: $0) }
            .min { distanceSquared($0, point) < distanceSquared($1, point) }
    }

    static func clamp(_ point: CGPoint, into rect: CGRect) -> CGPoint {
        // maxX/maxY are exclusive for the cursor; stay one point inside.
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX - 1),
            y: min(max(point.y, rect.minY), rect.maxY - 1)
        )
    }

    static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }
}
