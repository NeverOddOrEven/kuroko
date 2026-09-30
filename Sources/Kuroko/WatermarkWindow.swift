import AppKit

/// Faint, click-through mark centred on the source display, so you can tell at a glance which
/// display is being mirrored. Kuroko excludes its own windows from capture, so viewers never see it.
@MainActor
final class WatermarkWindow {
    private static let opacity: CGFloat = 0.08
    private static let size = NSSize(width: 360, height: 280)

    private let panel: WatermarkPanel

    init() {
        panel = WatermarkPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = Self.makeContent()
    }

    /// Centres the mark on the given screen; hides it when there's none.
    func show(on screen: NSScreen?) {
        guard let screen else {
            panel.orderOut(nil)
            return
        }
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.midY - Self.size.height / 2))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private static func makeContent() -> NSView {
        let color = NSColor(white: 0.5, alpha: opacity)
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 160, weight: .light)
        symbol.contentTintColor = color
        let name = NSTextField(labelWithString: "Kuroko")
        name.font = .systemFont(ofSize: 40, weight: .light)
        name.textColor = color
        let stack = NSStackView(views: [symbol, name])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        return stack
    }
}

private final class WatermarkPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
