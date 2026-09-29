import CoreGraphics
import Testing
@testable import KurokoCore

struct DisplayGeometryTests {
    @Test func retinaSpecIsHiDPI() {
        let spec = DisplayModeSpec(pointWidth: 1470, pointHeight: 956, pixelWidth: 2940, pixelHeight: 1912, refreshRate: 0)
        #expect(spec.isHiDPI)
        #expect(spec.effectiveRefreshRate == 60)
    }

    @Test func nonRetinaSpecIsNotHiDPI() {
        let spec = DisplayModeSpec(pointWidth: 1920, pointHeight: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
        #expect(!spec.isHiDPI)
    }

    @Test func fitsWithinMaximumPixels() {
        let spec = DisplayModeSpec(pointWidth: 1470, pointHeight: 956, pixelWidth: 2940, pixelHeight: 1912, refreshRate: 60)
        #expect(spec.fits(maxPixelWidth: 2940, maxPixelHeight: 1912))
        #expect(!spec.fits(maxPixelWidth: 2939, maxPixelHeight: 1912))
        #expect(!spec.fits(maxPixelWidth: 2940, maxPixelHeight: 1911))
    }

    @Test func matchesOnlyTheSamePointAndPixelSize() {
        let spec = DisplayModeSpec(pointWidth: 1470, pointHeight: 956, pixelWidth: 2940, pixelHeight: 1912, refreshRate: 60)
        #expect(spec.matches(width: 1470, height: 956, pixelWidth: 2940, pixelHeight: 1912))
        #expect(!spec.matches(width: 2940, height: 1912, pixelWidth: 2940, pixelHeight: 1912))
    }

    @Test func hiDPIOffersPixelAndPointSizes() {
        let spec = DisplayModeSpec(pointWidth: 1470, pointHeight: 956, pixelWidth: 2940, pixelHeight: 1912, refreshRate: 60)
        #expect(spec.virtualModeSizes == [CGSize(width: 2940, height: 1912), CGSize(width: 1470, height: 956)])
    }

    @Test func nonHiDPIOffersOnlyPixelSize() {
        let spec = DisplayModeSpec(pointWidth: 1920, pointHeight: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
        #expect(spec.virtualModeSizes == [CGSize(width: 1920, height: 1080)])
    }

    @Test func physicalSizeKeepsAspectRatio() {
        let spec = DisplayModeSpec(pointWidth: 1470, pointHeight: 956, pixelWidth: 2940, pixelHeight: 1912, refreshRate: 60)
        let size = DisplayGeometry.sizeInMillimeters(for: spec)
        #expect(abs(size.width / size.height - 2940.0 / 1912.0) < 0.001)
    }

    @Test func parksOffBottomRightOfAllDisplays() {
        let main = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        #expect(DisplayGeometry.parkingOrigin(physicalDisplayBounds: [main, left]) == CGPoint(x: 1470, y: 956))
    }

    @Test func parkingWithNoDisplaysIsOrigin() {
        #expect(DisplayGeometry.parkingOrigin(physicalDisplayBounds: []) == .zero)
    }

    @Test func nearestPointClampsIntoClosestDisplay() {
        let main = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let point = CGPoint(x: 1600, y: 1000)
        #expect(DisplayGeometry.nearestPoint(to: point, in: [main]) == CGPoint(x: 1469, y: 955))
    }

    @Test func nearestPointPicksCloserOfTwoDisplays() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 500)
        let point = CGPoint(x: 1500, y: 600)
        #expect(DisplayGeometry.nearestPoint(to: point, in: [main, right]) == CGPoint(x: 1500, y: 499))
    }

    @Test func pointInsideRectIsUnchanged() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(DisplayGeometry.nearestPoint(to: CGPoint(x: 5, y: 5), in: [main]) == CGPoint(x: 5, y: 5))
    }
}
