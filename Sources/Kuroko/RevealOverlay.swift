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
        /// An app switch is about to happen, to `target` if it's known.
        case appSwitch(since: ContinuousClock.Instant, target: pid_t?)
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
        timer.tolerance = 0.005
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
        input.onAppSwitch = { [weak self] app in self?.coverForAppSwitch(to: app) }
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
        var reordered = false
        for target in targets {
            let tint = tints[target.windowID] ?? makeTint(for: target)
            tints[target.windowID] = tint
            tint.update(target: target, dismissed: state.dismissed.contains(target.appID))
            // Reorder only when something came between the tint and its window, such as the
            // hidden app being brought forward: reordering interrupts other windows' drags.
            if !Self.isDirectlyAbove(tint.windowID, target.windowID, in: stacking) {
                tint.order(above: target)
                reordered = true
            }
        }
        // Window changes otherwise reach the window server only at the end of this run-loop
        // turn, and the cover's in-place check below would miss them until the next tick.
        if reordered { CATransaction.flush() }
        if cover != nil, let screen = Displays.screen(for: state.displayID) {
            refreshCover(windows: windows, state: state, screen: screen)
            coverPanel.commitContent()
        }
        endCoverIfSettled(windows: windows, targets: targets, reordered: reordered)
    }

    private func makeTint(for target: OverlayTarget) -> WindowTint {
        let tint = WindowTint(
            appName: Self.name(of: target.appID),
            reveal: { [weak self] in self?.onReveal(target.appID) },
            dismiss: { [weak self] in self?.onDismiss(target.appID) }
        )
        // Under a cover, the cover draws this window's tint.
        tint.isTransparent = cover != nil
        tint.onClick = { [weak self, weak tint] in
            guard let self, let target = tint?.target else { return }
            beginCover(.raise(target.windowID))
            WindowFocus.raise(pid: target.ownerPID, bounds: target.bounds)
        }
        return tint
    }

    private func tick() {
        update()
        // Rescheduled rather than skipping ticks, which would still wake the process.
        let idle = ContinuousClock.now - lastChange > .seconds(1) && cover == nil
        timer?.fireDate = Date(timeIntervalSinceNow: idle ? 0.1 : 1.0 / 30)
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
        let all = WindowList.onScreen()
        let windows = all.filter { $0.ownerPID != ownPID }
        guard let clicked = windows.first(where: { $0.bounds.contains(point) }) else { return }
        if bundleID(of: clicked.ownerPID) == "com.apple.dock" {
            // A Dock icon that isn't a running app launches one, whose windows are new and
            // get tints as they appear; there's nothing on screen to cover.
            if let app = AppSwitcher.dockApp(at: point) { coverForAppSwitch(to: app) }
            return
        }
        let front = windows.first { $0.layer == clicked.layer }
        guard let tint = tints[clicked.windowID], tint.isDismissed, front?.windowID != clicked.windowID else { return }
        beginCover(.raise(clicked.windowID), windows: all)
    }

    // MARK: - Cover

    /// Covers only when a hidden app is coming forward: a revealed app, or one with no tinted
    /// windows, moves nothing that's tinted. An unknown target (the switcher couldn't be read)
    /// could be any hidden app.
    private func coverForAppSwitch(to app: NSRunningApplication?) {
        if let app {
            guard tints.values.contains(where: { $0.target?.ownerPID == app.processIdentifier }) else { return }
        }
        beginCover(.appSwitch(since: .now, target: app?.processIdentifier))
    }

    /// Raised windows jump above their tints, which can only be reordered afterwards. So before
    /// anything raises a hidden window, one panel above all normal windows takes over from the
    /// tints, which go transparent until each is back on top of its window. The panel paints
    /// the tints as they will look once the windows have moved, so taking it down changes
    /// nothing on screen.
    private func beginCover(_ reason: CoverReason, windows: [WindowSnapshot]? = nil) {
        guard let state = state(), let screen = Displays.screen(for: state.displayID), !tints.isEmpty else { return }
        cover = (reason, .now + .seconds(1))
        refreshCover(windows: windows ?? WindowList.onScreen(), state: state, screen: screen)
        coverPanel.commitContent()
        // Called from the event tap, so this must reach the screen before the event is released.
        Self.atomically {
            coverPanel.orderFront()
            tints.values.forEach { $0.isTransparent = true }
        }
    }

    /// Paints the tints for the predicted stacking: the windows about to come forward moved in
    /// front of the rest of their layer.
    private func refreshCover(windows: [WindowSnapshot], state: State, screen: NSScreen) {
        guard let cover else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let rank = risingRank(cover.reason, state: state)
        let predicted = windows.filter { $0.ownerPID != ownPID }.enumerated()
            .sorted { a, b in
                (-a.element.layer, rank(a.element), a.offset) < (-b.element.layer, rank(b.element), b.offset)
            }
            .map(\.element)
        let display = CGDisplayBounds(state.displayID)
        let targets = OverlayLayout.targets(
            windows: predicted, display: display, appID: { self.bundleID(of: $0) }, isHidden: state.isHidden
        )
        let targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.windowID, $0) })
        let normal = predicted.filter { OverlayLayout.coveredLayers.contains($0.layer) }
        let local = { (rect: CGRect) in rect.offsetBy(dx: -display.minX, dy: -display.minY) }

        var areas: [CoverView.Area] = []
        var prompts: [CoverView.Prompt] = []
        for (index, window) in normal.enumerated().reversed() {
            let target = targetsByID[window.windowID]
            let dismissed = target.map { state.dismissed.contains($0.appID) } ?? false
            // Windows that aren't tinted are painted clear, so they don't show a stray tint.
            let color = target == nil ? NSColor.clear : dismissed ? TintColor.dismissed : TintColor.hidden
            areas.append(.init(rect: local(window.bounds), color: color))
            guard let target, target.showsPrompt, !dismissed else { continue }
            prompts.append(.init(
                appName: tints[target.windowID]?.appName ?? Self.name(of: target.appID),
                windowRect: local(window.bounds),
                occluders: normal[..<index].map { local($0.bounds) }
            ))
        }
        coverPanel.update(on: screen, areas: areas, prompts: prompts)
    }

    /// Sort key for the predicted stacking: lower comes first within a layer.
    private func risingRank(_ reason: CoverReason, state: State) -> (WindowSnapshot) -> Int {
        switch reason {
        case .raise(let id):
            // Activating the app brings its other windows forward too, behind the raised one.
            let owner = lastWindows.first { $0.windowID == id }?.ownerPID
            return { $0.windowID == id ? 0 : $0.ownerPID == owner ? 1 : 2 }
        case .appSwitch(let since, let target):
            if lastActivation > since, let pid = lastActivatedPID {
                return { $0.ownerPID == pid ? 0 : 1 }
            }
            if let target {
                return { $0.ownerPID == target ? 0 : 1 }
            }
            // The app being switched to isn't known, so assume any hidden app may come forward.
            return { self.bundleID(of: $0.ownerPID).map(state.isHidden) ?? false ? 0 : 1 }
        }
    }

    private func endCoverIfSettled(windows: [WindowSnapshot], targets: [OverlayTarget], reordered: Bool) {
        guard let cover else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let timedOut = ContinuousClock.now >= cover.deadline
        let settled: Bool
        switch cover.reason {
        case .raise(let id):
            let layer = windows.first { $0.windowID == id }?.layer ?? 0
            settled = windows.first { $0.layer == layer && $0.ownerPID != ownPID }?.windowID == id
        case .appSwitch(let since, _):
            if lastActivation > since, let pid = lastActivatedPID, targets.contains(where: { $0.ownerPID == pid }) {
                // The app switched to raises its windows only after it's reported active.
                settled = windows.first { $0.layer == 0 && $0.ownerPID != ownPID }?.ownerPID == pid
            } else {
                settled = lastActivation > since || ContinuousClock.now - since > .milliseconds(300)
            }
        }
        guard settled || timedOut else { return }
        // Only a reorder since `windows` was listed can have changed the stacking.
        let stacking = reordered ? Self.currentStacking() : windows.map(\.windowID)
        let inPlace = targets.allSatisfy { target in
            tints[target.windowID].map { Self.isDirectlyAbove($0.windowID, target.windowID, in: stacking) } ?? true
        }
        guard inPlace || timedOut else { return }
        endCover()
    }

    private func endCover() {
        guard cover != nil else { return }
        cover = nil
        Self.atomically {
            tints.values.forEach { $0.isTransparent = false }
            coverPanel.hide()
        }
    }

    /// Applies window changes together and pushes them to the window server now, rather than
    /// at the end of the run-loop turn, so no frame shows the cover and the tints both or
    /// neither.
    private static func atomically(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            changes()
        }
        CATransaction.flush()
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
    private let content = ClickView()
    private(set) var color = TintColor.hidden

    init(appName: String, reveal: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.appName = appName
        panel = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        // The tint is the content layer's colour: a window background would be drawn into a
        // window-sized bitmap, and redrawn on every resize.
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        prompt = AppButtons(appName: appName, reveal: reveal, dismiss: dismiss)
        prompt.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = color.cgColor
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
    var visiblePromptSize: CGSize? { prompt.isHidden ? nil : prompt.fittingSize }

    var isTransparent: Bool {
        get { panel.alphaValue == 0 }
        set { panel.alphaValue = newValue ? 0 : 1 }
    }

    func update(target: OverlayTarget, dismissed: Bool) {
        self.target = target
        let frame = Self.cocoaFrame(for: target.bounds)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        // Only on change: setting a window's level can reorder it.
        let level = NSWindow.Level(rawValue: target.layer)
        if panel.level != level { panel.level = level }
        let color = dismissed ? TintColor.dismissed : TintColor.hidden
        if self.color != color {
            self.color = color
            content.layer?.backgroundColor = color.cgColor
        }
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

    func update(on screen: NSScreen, areas: [CoverView.Area], prompts: [CoverView.Prompt]) {
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        view.show(areas: areas, prompts: prompts)
    }

    /// Draws and sends the content now, so the panel never appears with last time's content.
    func commitContent() {
        panel.displayIfNeeded()
        CATransaction.flush()
    }

    func orderFront() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class CoverView: NSView {
    struct Area: Equatable {
        var rect: CGRect
        var color: NSColor
    }

    struct Prompt: Equatable {
        var appName: String
        /// The window the prompt is centred on, like the real one.
        var windowRect: CGRect
        /// Windows in front of it, which hide those parts of the prompt.
        var occluders: [CGRect]
    }

    /// Back to front.
    private var areas: [Area] = []
    /// Reused between covers: building them inside the event tap delays the event, and new ones
    /// can take a frame to render.
    private var promptPool: [PromptCopy] = []

    // Matches the window server's top-left coordinates.
    override var isFlipped: Bool { true }

    private var prompts: [Prompt] = []

    func show(areas: [Area], prompts: [Prompt]) {
        // Refreshed every tick while up; most ticks change nothing.
        guard areas != self.areas || prompts != self.prompts else { return }
        self.areas = areas
        self.prompts = prompts
        while promptPool.count < prompts.count {
            let copy = PromptCopy()
            addSubview(copy)
            promptPool.append(copy)
        }
        for (copy, prompt) in zip(promptPool, prompts) {
            copy.appName = prompt.appName
            let size = copy.promptSize
            let centred = CGRect(
                x: prompt.windowRect.midX - size.width / 2, y: prompt.windowRect.midY - size.height / 2,
                width: size.width, height: size.height
            )
            // Pixel-aligned, as Auto Layout aligns the real prompt.
            let frame = backingAlignedRect(centred, options: .alignAllEdgesNearest)
            copy.show(frame: frame, visible: RectMath.subtract(prompt.occluders, from: frame))
        }
        promptPool.dropFirst(prompts.count).forEach { $0.isHidden = true }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        // Overwrite rather than blend, so where windows overlap the front one's tint shows once
        // instead of the tints stacking into a darker grey.
        for area in areas {
            area.color.setFill()
            area.rect.fill(using: .copy)
        }
    }
}

/// A non-interactive copy of a prompt, masked to the parts windows in front don't hide.
private final class PromptCopy: NSView {
    private let buttons = AppButtons(appName: "", reveal: {}, dismiss: {})
    private let mask = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        buttons.autoresizingMask = [.width, .height]
        addSubview(buttons)
        layer?.mask = mask
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    var appName: String {
        get { buttons.appName }
        set { buttons.appName = newValue }
    }

    var promptSize: CGSize { buttons.fittingSize }

    /// `frame` and `visible` are in the parent's flipped (top-left) coordinates.
    func show(frame: CGRect, visible: [CGRect]) {
        isHidden = visible.isEmpty
        guard !visible.isEmpty else { return }
        self.frame = frame
        buttons.frame = bounds
        // This view isn't flipped: its layer's origin is bottom-left.
        let path = CGMutablePath()
        for piece in visible {
            path.addRect(CGRect(
                x: piece.minX - frame.minX, y: frame.maxY - piece.maxY,
                width: piece.width, height: piece.height
            ))
        }
        mask.frame = bounds
        mask.path = path
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
    private let label = NSTextField(labelWithString: "")

    var appName = "" {
        didSet { updateLabel() }
    }

    init(appName: String, reveal: @escaping () -> Void, dismiss: @escaping () -> Void) {
        super.init(frame: .zero)
        material = .hudWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14

        self.appName = appName
        updateLabel()  // didSet doesn't run for assignments in init
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

    private func updateLabel() {
        label.stringValue = "\(appName) is hidden from viewers"
    }
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
