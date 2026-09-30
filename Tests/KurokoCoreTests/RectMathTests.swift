import CoreGraphics
import Testing
@testable import KurokoCore

struct RectMathTests {
    let rect = CGRect(x: 0, y: 0, width: 30, height: 30)

    func area(_ rects: [CGRect]) -> CGFloat {
        rects.map { $0.width * $0.height }.reduce(0, +)
    }

    @Test func holeInTheMiddleLeavesFourPieces() {
        let pieces = RectMath.subtract([CGRect(x: 10, y: 10, width: 10, height: 10)], from: rect)
        #expect(pieces.count == 4)
        #expect(area(pieces) == 800)
    }

    @Test func disjointHoleLeavesTheRectAlone() {
        #expect(RectMath.subtract([CGRect(x: 50, y: 50, width: 10, height: 10)], from: rect) == [rect])
    }

    @Test func coveringHoleLeavesNothing() {
        #expect(RectMath.subtract([CGRect(x: -5, y: -5, width: 40, height: 40)], from: rect).isEmpty)
    }

    @Test func overlappingHolesAreSubtractedOnce() {
        let holes = [CGRect(x: 0, y: 0, width: 20, height: 30), CGRect(x: 10, y: 0, width: 20, height: 30)]
        #expect(RectMath.subtract(holes, from: rect).isEmpty)
        let partial = [CGRect(x: 0, y: 0, width: 20, height: 10), CGRect(x: 10, y: 0, width: 10, height: 20)]
        #expect(area(RectMath.subtract(partial, from: rect)) == 600)
    }
}
