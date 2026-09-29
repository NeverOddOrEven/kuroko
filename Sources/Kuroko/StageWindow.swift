import AppKit

/// Borderless, click-through panel that fills the virtual display. This is what Teams shares.
@MainActor
final class StageWindow {
    private let panel: StagePanel
    private let frameView = FrameView()

    init() {
        panel = StagePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver  // above the virtual display's own menu bar
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = frameView
    }

    /// Fills the given screen; hides the panel while the screen isn't available yet.
    func show(on screen: NSScreen?) {
        guard let screen else {
            panel.orderOut(nil)
            return
        }
        frameView.contentsScale = screen.backingScaleFactor
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    func display(_ frame: StageFrame) {
        frameView.show(frame)
    }

    func close() {
        panel.orderOut(nil)
    }
}

private final class StagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
