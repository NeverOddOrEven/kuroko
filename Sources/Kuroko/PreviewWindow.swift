import AppKit

/// Optional floating window on the real screen showing exactly what viewers see.
@MainActor
final class PreviewWindow: NSObject, NSWindowDelegate {
    var onClose: () -> Void = {}

    private let window: NSWindow
    private let frameView = FrameView()

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 312),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Kuroko Preview"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Center only when there's no saved frame yet; afterwards the saved frame wins.
        if !window.setFrameUsingName("KurokoPreview") { window.center() }
        window.setFrameAutosaveName("KurokoPreview")
        window.delegate = self
        window.contentView = frameView
    }

    var isVisible: Bool { window.isVisible }

    func show(aspectRatio: CGSize) {
        window.contentAspectRatio = aspectRatio
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func display(_ frame: StageFrame) {
        guard window.isVisible else { return }
        frameView.show(frame)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
