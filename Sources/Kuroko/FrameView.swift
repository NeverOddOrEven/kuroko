import AppKit

enum StageFrame {
    case live(IOSurfaceRef)
    /// A copy that stays valid while capture is paused or stopped.
    case frozen(CGImage)
    /// Nothing; the view shows its black background.
    case blank
}

/// Shows stage frames letterboxed on black.
final class FrameView: NSView {
    private let frameLayer = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.backgroundColor = NSColor.black.cgColor
        layer = frameLayer
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    var contentsScale: CGFloat {
        get { frameLayer.contentsScale }
        set { frameLayer.contentsScale = newValue }
    }

    func show(_ frame: StageFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch frame {
        case .live(let surface): frameLayer.contents = surface
        case .frozen(let image): frameLayer.contents = image
        case .blank: frameLayer.contents = nil
        }
        CATransaction.commit()
    }
}
