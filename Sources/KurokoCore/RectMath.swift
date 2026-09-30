import CoreGraphics

public enum RectMath {
    /// `rect` minus every rect in `holes`, as non-overlapping rects.
    public static func subtract(_ holes: [CGRect], from rect: CGRect) -> [CGRect] {
        var pieces = [rect]
        for hole in holes {
            pieces = pieces.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(hole)
                guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [piece] }
                var rest: [CGRect] = []
                if cut.minY > piece.minY {
                    rest.append(CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY))
                }
                if cut.maxY < piece.maxY {
                    rest.append(CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY))
                }
                if cut.minX > piece.minX {
                    rest.append(CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height))
                }
                if cut.maxX < piece.maxX {
                    rest.append(CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height))
                }
                return rest
            }
        }
        return pieces
    }
}
