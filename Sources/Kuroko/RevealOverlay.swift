import AppKit
import KurokoCore

/// Tints each hidden app's windows on the source display, with Reveal and Dismiss buttons per
/// app. Purely a guide for the user: what viewers see is decided by the capture filter, so a
/// window this misses or lags behind is still hidden from them.
@MainActor
final class RevealOverlay {
    struct State {
        var displayID: CGDirectDisplayID
        var isHidden: (String) -> Bool
        var dismissed: Set<String>
    }

    /// Why the cover is up, which decides when it can come down.
    private enum CoverReason {
        /// Kuroko is raising this window, or a click is about to.
        case raise(CGWindowID)
        /// An app switch is about to happen, to an app that isn't known yet.
        case appSwitch(since: ContinuousClock.Instant)
    }

    var onReveal: (String) -> Void = { _ in }
    var onDismiss: (String) -> Void = { _ in }

    private var state: () -> State? = { nil }
    private var displayID: CGDirectDisplayID?
    private var timer: Timer?
    private var tints: [CGWindowID: WindowTint] = [:]
    private let coverPanel = CoverPanel()
    private var cover: (reason: CoverReason, deadline: ContinuousClock.Instant)?
    /// Polled at full rate for a while after windows change, and at a third of it when idle.
    private var lastWindows: [WindowSnapshot] = []
    private var lastChange = ContinuousClock.now
    private var ticks = 0
    private var activationObserver: NSObjectProtocol?
    private var lastActivation = ContinuousClock.now
    private var lastActivatedPID: pid_t?
    private let input = InputWatcher()
    /// Window owners' bundle IDs (nil for processes without one). Listing every running app on
    /// each update was the overlay's main cost.
    private var bundleIDs: [pid_t: String?] = [:]
    private var terminationObserver: NSObjectProtocol?

    func start(state: @escaping () -> State?) {
        self.state = state
        guard timer == nil else { return }
        // Common modes, so tints keep up while a menu is open.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.lastActivation = .now
                self?.lastActivatedPID = app?.processIdentifier
                self?.update()
            }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { app.map { self?.bundleIDs[$0.processIdentifier] = nil } }
        }
        input.onAppSwitch = { [weak self] in self?.beginCover(.appSwitch(since: .now)) }
        input.onMouseDown = { [weak self] point in self?.coverBeforeClick(at: point) }
        input.start()
        update()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        activationObserver = nil
        terminationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        terminationObserver = nil
        input.stop()
        endCover()
        tints.values.forEach { $0.close() }
        tints = [:]
    }

    private func update() {
        guard let state = state() else {
            endCover()
            tints.values.forEach { $0.close() }
            tints = [:]
            return
        }
        displayID = state.displayID
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = WindowList.onScreen()
        if windows != lastWindows {
            lastWindows = windows
            lastChange = .now
        }
        let targets = OverlayLayout.targets(
            windows: windows,
            display: CGDisplayBounds(state.displayID),
            appID: { $0 == ownPID ? nil : self.bundleID(of: $0) },
            isHidden: state.isHidden
        )

        let targeted = Set(targets.map(\.windowID))
        for (id, tint) in tints where !targeted.contains(id) {
            tint.close()
            tints[id] = nil
        }
        let stacking = windows.map(\.windowID)
        for target in targets {
            let tint = tints[target.windowID] ?? makeTint(for: target)
            tints[target.windowID] = tint
            tint.update(target: target, dismissed: state.dismissed.contains(target.appID))
            // Reorder only when something came between the tint and its window, such as the
            // hidden app being brought forward: reordering interrupts other windows' drags.
            if !Self.isDirectlyAbove(tint.windowID, target.windowID, in: stacking) {
                tint.order(above: target)
            }
        }
        endCoverIfSettled(windows: windows, targets: targets)
    }

    private func makeTint(for target: OverlayTarget) -> WindowTint {
        let tint = WindowTint(
            appName: Self.name(of: target.appID),
            reveal: { [weak self] in self?.onReveal(target.appID) },
            dismiss: { [weak self] in self?.onDismiss(target.appID) }
        )
        tint.onClick = { [weak self, weak tint] in
            guard let self, let target = tint?.target else { return }
            beginCover(.raise(target.windowID))
            WindowFocus.raise(pid: target.ownerPID, bounds: target.bounds)
        }
        return tint
    }

    private func tick() {
        ticks += 1
        let idle = ContinuousClock.now - lastChange > .seconds(1) && cover == nil
        guard !idle || ticks % 3 == 0 else { return }
        update()
    }

    private func bundleID(of pid: pid_t) -> String? {
        if let known = bundleIDs[pid] { return known }
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundleIDs[pid] = .some(id)
        return id
    }

    /// Clicks that raise a hidden window without going through its tint: a dismissed window
    /// (its tint lets clicks through) that isn't in front, or an app in the Dock.
    private func coverBeforeClick(at point: CGPoint) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = WindowList.onScreen().filter { $0.ownerPID != ownPID }
        guard let clicked = windows.first(where: { $0.bounds.contains(point) }) else { return }
        if NSRunningApplication(processIdentifier: clicked.ownerPID)?.bundleIdentifier == "com.apple.dock" {
            beginCover(.appSwitch(since: .now))
            return
        }
        let front = windows.first { $0.layer == clicked.layer }
        guard let tint = tints[clicked.windowID], tint.isDismissed, front?.windowID != clicked.windowID else { return }
        beginCover(.raise(clicked.windowID))
    }

    // MARK: - Cover

    /// Raised windows jump above their tints, which can only be reordered afterwards. So before
    /// anything raises a hidden window, one panel above all normal windows takes over from the
    /// tints, which go transparent until each is back on top of its window.
    private func beginCover(_ reason: CoverReason) {
        guard let displayID, let screen = Displays.screen(for: displayID), !tints.isEmpty else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let origin = CGDisplayBounds(displayID).origin
        let normal = WindowList.onScreen().filter {
            OverlayLayout.coveredLayers.contains($0.layer) && $0.ownerPID != ownPID
        }
        var areas: [CoverView.Area] = []
        var prompts: [CoverView.Prompt] = []
        for (index, window) in normal.enumerated().reversed() {
            guard let tint = tints[window.windowID] else { continue }
            areas.append(.init(rect: window.bounds.offsetBy(dx: -origin.x, dy: -origin.y), color: tint.color))
            guard let size = tint.visiblePromptSize else { continue }
            let rect = CGRect(
                x: window.bounds.midX - size.width / 2, y: window.bounds.midY - size.height / 2,
                width: size.width, height: size.height
            )
            // Copy only prompts that can be seen now, plus the one on a window about to come forward.
            let raised = if case .raise(window.windowID) = reason { true } else { false }
            guard raised || !normal[..<index].contains(where: { $0.bounds.intersects(rect) }) else { continue }
            prompts.append(.init(appName: tint.appName, rect: rect.offsetBy(dx: -origin.x, dy: -origin.y)))
        }
        coverPanel.show(on: screen, areas: areas, prompts: prompts)
        tints.values.forEach { $0.isTransparent = true }
        cover = (reason, .now + .seconds(1))
    }

    private func endCoverIfSettled(windows: [WindowSnapshot], targets: [OverlayTarget]) {
        guard let cover else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let timedOut = ContinuousClock.now >= cover.deadline
        let settled: Bool
        switch cover.reason {
        case .raise(let id):
            let layer = windows.first { $0.windowID == id }?.layer ?? 0
            settled = windows.first { $0.layer == layer && $0.ownerPID != ownPID }?.windowID == id
        case .appSwitch(let since):
            if lastActivation > since, let pid = lastActivatedPID, targets.contains(where: { $0.ownerPID == pid }) {
                // The app switched to raises its windows only after it's reported active.
                settled = windows.first { $0.layer == 0 && $0.ownerPID != ownPID }?.ownerPID == pid
            } else {
                settled = lastActivation > since || ContinuousClock.now - since > .milliseconds(300)
            }
        }
        guard settled || timedOut else { return }
        let stacking = Self.currentStacking()
        let inPlace = targets.allSatisfy { target in
            tints[target.windowID].map { Self.isDirectlyAbove($0.windowID, target.windowID, in: stacking) } ?? true
        }
        guard inPlace || timedOut else { return }
        endCover()
    }

    private func endCover() {
        guard cover != nil else { return }
        cover = nil
        tints.values.forEach { $0.isTransparent = false }
        coverPanel.hide()
    }

    /// Window IDs front to back.
    private static func currentStacking() -> [CGWindowID] {
        WindowList.onScreen().map(\.windowID)
    }

    private static func isDirectlyAbove(_ window: CGWindowID, _ other: CGWindowID, in stacking: [CGWindowID]) -> Bool {
        guard let index = stacking.firstIndex(of: window), let otherIndex = stacking.firstIndex(of: other) else { return false }
        return index + 1 == otherIndex
    }

    private static func name(of bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }
}

private enum TintColor {
    static let hidden = NSColor(white: 0.35, alpha: 0.6)
    static let dismissed = NSColor(white: 0.35, alpha: 0.3)
}

/// A tint over one hidden window, ordered directly above it so windows in front of it still
/// draw over the tint.
@MainActor
private final class WindowTint {
    let appName: String
    var onClick: () -> Void = {}
    private(set) var target: OverlayTarget?
    private let panel: NonKeyPanel
    private let prompt: AppButtons

    init(appName: String, reveal: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.appName = appName
        panel = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = TintColor.hidden
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        prompt = AppButtons(appName: appName, reveal: reveal, dismiss: dismiss)
        prompt.translatesAutoresizingMaskIntoConstraints = false
        let content = ClickView()
        content.addSubview(prompt)
        NSLayoutConstraint.activate([
            prompt.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            prompt.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
        content.onClick = { [weak self] in self?.onClick() }
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }
    var isDismissed: Bool { panel.ignoresMouseEvents }
    var color: NSColor { panel.backgroundColor }
    var visiblePromptSize: CGSize? { prompt.isHidden ? nil : prompt.fittingSize }

    var isTransparent: Bool {
        get { panel.alphaValue == 0 }
        set { panel.alphaValue = newValue ? 0 : 1 }
    }

    func update(target: OverlayTarget, dismissed: Bool) {
        self.target = target
        let frame = Self.cocoaFrame(for: target.bounds)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        // Only on change: setting a window's level can reorder it.
        let level = NSWindow.Level(rawValue: target.layer)
        if panel.level != level { panel.level = level }
        let color = dismissed ? TintColor.dismissed : TintColor.hidden
        if panel.backgroundColor != color { panel.backgroundColor = color }
        // Undismissed tints block input to their window; dismissed ones let it through.
        if panel.ignoresMouseEvents != dismissed { panel.ignoresMouseEvents = dismissed }
        prompt.isHidden = dismissed || !target.showsPrompt
    }

    func order(above target: OverlayTarget) {
        panel.order(.above, relativeTo: Int(target.windowID))
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Window-server rects are top-left based on the primary display; AppKit frames are
    /// bottom-left based.
    private static func cocoaFrame(for bounds: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

/// Stands in for the tints while windows are raised, above all normal windows.
@MainActor
private final class CoverPanel {
    private let panel: NonKeyPanel
    private let view = CoverView()

    init() {
        panel = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
    }

    func show(on screen: NSScreen, areas: [CoverView.Area], prompts: [CoverView.Prompt]) {
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        view.show(areas: areas, prompts: prompts)
        // Drawn before it appears, so it never shows stale or empty.
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class CoverView: NSView {
    struct Area {
        var rect: CGRect
        var color: NSColor
    }

    struct Prompt {
        var appName: String
        var rect: CGRect
    }

    /// Back to front.
    private var areas: [Area] = []
    private var promptViews: [AppButtons] = []

    // Matches the window server's top-left coordinates.
    override var isFlipped: Bool { true }

    func show(areas: [Area], prompts: [Prompt]) {
        self.areas = areas
        promptViews.forEach { $0.removeFromSuperview() }
        promptViews = prompts.map { prompt in
            let view = AppButtons(appName: prompt.appName, reveal: {}, dismiss: {})
            view.frame = prompt.rect
            addSubview(view)
            return view
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Overwrite rather than blend, so where windows overlap the front one's tint shows once
        // instead of the tints stacking into a darker grey.
        for area in areas {
            area.color.setFill()
            area.rect.fill(using: .copy)
        }
    }
}

/// Takes a click anywhere outside the prompt, including the first click into the non-key panel.
private final class ClickView: NSView {
    var onClick: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}

/// App name with Reveal and Dismiss buttons, centred on a hidden app's frontmost window.
private final class AppButtons: NSVisualEffectView {
    init(appName: String, reveal: @escaping () -> Void, dismiss: @escaping () -> Void) {
        super.init(frame: .zero)
        material = .hudWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14

        let label = NSTextField(labelWithString: "\(appName) is hidden from viewers")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let revealButton = FirstClickButton(title: "Reveal", action: reveal)
        revealButton.keyEquivalent = "\r"
        let dismissButton = FirstClickButton(title: "Dismiss", action: dismiss)
        let buttons = NSStackView(views: [dismissButton, revealButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }
}

/// The overlay never becomes key, so its buttons must act on the first click.
private final class FirstClickButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, action handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() { handler() }
}

private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
