import AppKit
import KurokoCore
import ScreenCaptureKit

enum StageState: Equatable {
    case starting
    case live
    case paused
    /// Capture was stopped from the macOS screen-recording menu; stays off until resumed.
    case stopped
    case needsPermission
    case failed(String)
}

/// Wires the virtual display, capture, windows and system hooks together.
@MainActor
final class AppController {
    let prefs = Preferences()
    private let virtualDisplay = VirtualDisplayManager()
    private let capture = StageCapture()
    private let stage = StageWindow()
    private let preview = PreviewWindow()
    private var cursorGuard: CursorGuard?
    private var hotKey: HotKey?
    private var observers: [NSObjectProtocol] = []
    private var filterTimer: Timer?
    private var restartTask: Task<Void, Never>?
    private var retry = RetryBackoff()
    private let permissionWatcher = PermissionWatcher()
    private var reconcileTask: Task<Void, Never>?
    private var toggleTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var isFilterRefreshQueued = false

    /// Set while the running filter may still show an app the user has since excluded. Fails
    /// closed: the stage stays black, rather than frozen on a frame that could show the app.
    private var isFilterBehind = false {
        didSet {
            guard isFilterBehind, !oldValue else { return }
            log.info("Filter is behind the exclusion list; blanking the stage")
            present(.blank)
        }
    }

    /// Excluded apps that are launching but not yet excluded by the filter. The stage holds a
    /// frame from before the launch meanwhile, since the app can open a window before the
    /// filter learns about it.
    private var launchingExcludedPIDs: Set<pid_t> = []
    private var launchHoldDeadline = ContinuousClock.now
    private var launchHoldTask: Task<Void, Never>?

    private(set) var sourceDisplayID: CGDirectDisplayID?
    private var sourceSpec: DisplayModeSpec?

    var onStateChange: () -> Void = {}
    private(set) var state: StageState = .starting {
        didSet { if state != oldValue { onStateChange() } }
    }

    var policy: ExclusionPolicy {
        ExclusionPolicy(excludedBundleIDs: prefs.excludedBundleIDs, selfProcessID: ProcessInfo.processInfo.processIdentifier)
    }

    var physicalDisplayIDs: [CGDirectDisplayID] {
        Displays.physicalDisplayIDs(excluding: virtualDisplay.displayID)
    }

    func launch() {
        capture.onFrame = { [weak self] surface in
            guard let self, !self.isFilterBehind, self.launchingExcludedPIDs.isEmpty else { return }
            self.present(.live(surface))
        }
        capture.onStop = { [weak self] error in self?.handleStreamStop(error) }
        preview.onClose = { [weak self] in self?.prefs.showPreview = false }

        cursorGuard = CursorGuard(
            virtualBounds: { [weak self] in self?.virtualDisplay.displayID.map(CGDisplayBounds) },
            physicalBounds: { [weak self] in self?.physicalDisplayIDs.map(CGDisplayBounds) ?? [] }
        )
        cursorGuard?.start()
        hotKey = HotKey { [weak self] in self?.togglePause() }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFilter() }
            })
        }
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { app.map { self?.holdStageWhileLaunching($0) } }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile() }
        })
        // Backstop for windows from processes that never post a launch notification.
        filterTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFilter() }
        }

        if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
        }
        Task { await startStage() }
    }

    func shutdown() {
        filterTimer?.invalidate()
        permissionWatcher.cancel()
        cursorGuard?.stop()
        stage.close()
        virtualDisplay.destroy()
    }

    // MARK: - Actions

    func togglePause() {
        // Each press acts on the state the previous one left behind.
        let previous = toggleTask
        toggleTask = Task {
            await previous?.value
            switch state {
            case .live:
                await capture.pause()
                freezeStage()
                state = .paused
            case .paused:
                do {
                    try await capture.resume()
                    state = .live
                    if isFilterBehind { refreshFilter() }
                } catch {
                    log.error("Resume failed: \(error.localizedDescription, privacy: .public)")
                    scheduleRestart()
                }
            case .stopped:
                retry.reset()
                await recoverCapture()
            default:
                break
            }
        }
    }

    func selectSource(_ id: CGDirectDisplayID) {
        guard id != sourceDisplayID else { return }
        prefs.sourceDisplayUUID = Displays.uuidString(for: id)
        restart()
    }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        prefs.setExcluded(bundleID, excluded)
        refreshFilter()
    }

    func setFrameRate(_ fps: Int) {
        prefs.frameRate = fps
        Task {
            do {
                try await capture.setFrameRate(prefs.frameRate)
                log.info("Frame rate set to \(fps, privacy: .public) fps")
            } catch {
                log.error("Frame rate change failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setPreviewVisible(_ visible: Bool) {
        prefs.showPreview = visible
        if visible { showPreview() } else { preview.hide() }
    }

    // MARK: - Lifecycle

    private func startStage() async {
        guard Permissions.hasScreenRecording else {
            waitForPermission()
            return
        }
        virtualDisplay.unmirror()
        let physical = physicalDisplayIDs
        let source = resolveSource(among: physical)
        guard let spec = Displays.modeSpec(for: source) else {
            state = .failed("Can't read mode of display \(source)")
            return
        }
        do {
            try await virtualDisplay.ensureDisplay(matching: spec)
            virtualDisplay.unmirror()
            virtualDisplay.park(physicalDisplayBounds: physicalDisplayIDs.map(CGDisplayBounds))
            sourceDisplayID = source
            sourceSpec = spec
            showStage()
            try await capture.start(sourceDisplayID: source, spec: spec, frameRate: prefs.frameRate, policy: policy)
            state = .live
            retry.reset()
            checkFilterAfterStart()
            if prefs.showPreview { showPreview() }
        } catch is CancellationError {
            // Superseded by a newer start, which owns the state now.
        } catch {
            handleStartFailure(error)
        }
    }

    /// Restarts only the capture when the virtual display is still valid, so a stream hiccup
    /// never reconfigures the display that Teams is sharing or listing.
    private func recoverCapture() async {
        guard Permissions.hasScreenRecording else {
            waitForPermission()
            return
        }
        guard let source = sourceDisplayID, let spec = sourceSpec,
              virtualDisplay.displayID != nil,
              physicalDisplayIDs.contains(source),
              Displays.modeSpec(for: source) == spec
        else {
            await startStage()
            return
        }
        do {
            try await capture.start(sourceDisplayID: source, spec: spec, frameRate: prefs.frameRate, policy: policy)
            state = .live
            retry.reset()
            checkFilterAfterStart()
        } catch is CancellationError {
            // Superseded by a newer start, which owns the state now.
        } catch {
            handleStartFailure(error)
        }
    }

    private func handleStartFailure(_ error: Error) {
        log.error("Start failed: \(String(describing: error), privacy: .public)")
        let response = StartFailureResponse(
            permissionDeclined: error.isStreamError(.userDeclined),
            hasPermission: Permissions.hasScreenRecording
        )
        switch response {
        case .needsRelaunch:
            log.info("Screen Recording granted but declined for this process; relaunch needed")
            state = .needsPermission
        case .waitForPermission:
            waitForPermission()
        case .retry:
            state = .failed(String(describing: error))
            scheduleRestart()
        }
    }

    private func waitForPermission() {
        state = .needsPermission
        permissionWatcher.waitUntilGranted { [weak self] in
            Task { await self?.startStage() }
        }
    }

    /// macOS sometimes applies a new Screen Recording grant only to a fresh process.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                log.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func handleStreamStop(_ error: Error) {
        freezeStage()
        if error.isStreamError(.userStopped) {
            // The user stopped us from the macOS menu bar; don't override that.
            state = .stopped
            return
        }
        state = .starting
        scheduleRestart()
    }

    private func restart() {
        restartTask?.cancel()
        restartTask = Task {
            await capture.stop()
            // Clear before starting, so a failed start can schedule its retry.
            guard !Task.isCancelled else { return }
            restartTask = nil
            await startStage()
        }
    }

    private func scheduleRestart() {
        guard restartTask == nil else { return }
        let delay = retry.nextDelay()
        restartTask = Task {
            try? await Task.sleep(for: delay)
            // A cancelled task has been superseded; leave the new one's reference alone.
            guard !Task.isCancelled else { return }
            restartTask = nil
            guard !capture.isRunning else { return }
            await recoverCapture()
        }
    }

    /// Holds the last frame on the stage (and preview) while capture is paused or stopped.
    private func freezeStage() {
        // The last frame came from a filter that may show an app the user has excluded.
        guard !isFilterBehind, let frozen = capture.snapshotLastFrame() else { return }
        present(.frozen(frozen))
    }

    private func present(_ frame: StageFrame) {
        stage.display(frame)
        preview.display(frame)
    }

    private func resolveSource(among physical: [CGDirectDisplayID]) -> CGDirectDisplayID {
        SourceDisplay.resolve(
            savedUUID: prefs.sourceDisplayUUID,
            displays: physical.map { ($0, Displays.uuidString(for: $0)) },
            mainID: CGMainDisplayID()
        )
    }

    /// Will-launch arrives before the app is shareable content, so a refresh can't exclude it
    /// yet. Hold the stage and retry until the filter excludes it, it quits, or the deadline
    /// passes; after that, did-launch and the timer refresh as usual.
    private func holdStageWhileLaunching(_ app: NSRunningApplication) {
        guard capture.isRunning, let bundleID = app.bundleIdentifier,
              prefs.excludedBundleIDs.contains(bundleID)
        else { return }
        if launchingExcludedPIDs.isEmpty { freezeStage() }
        launchingExcludedPIDs.insert(app.processIdentifier)
        launchHoldDeadline = .now + .seconds(3)
        log.info("Holding the stage while \(bundleID, privacy: .public) launches")
        guard launchHoldTask == nil else { return }
        launchHoldTask = Task {
            while !launchingExcludedPIDs.isEmpty, ContinuousClock.now < launchHoldDeadline {
                refreshFilter()
                await filterTask?.value
                launchingExcludedPIDs = launchingExcludedPIDs.filter {
                    !capture.excludes($0) && NSRunningApplication(processIdentifier: $0) != nil
                }
                if !launchingExcludedPIDs.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            }
            if !launchingExcludedPIDs.isEmpty {
                log.error("Launching app not excluded before the deadline; resuming the stage")
            }
            launchingExcludedPIDs = []
            launchHoldTask = nil
            log.info("Stage hold released")
        }
    }

    // MARK: - Display changes

    private func scheduleReconcile() {
        // Cancel the pending pass but let a running one finish first, so passes never overlap.
        let previous = reconcileTask
        previous?.cancel()
        reconcileTask = Task {
            await previous?.value
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await reconcile()
        }
    }

    /// Follows the source display's resolution/scaling, handles its disconnection, and keeps
    /// the virtual display unmirrored and parked and the stage window on it.
    private func reconcile() async {
        virtualDisplay.unmirror()
        let physical = physicalDisplayIDs
        guard let source = sourceDisplayID, capture.isRunning else {
            showStage()
            return
        }
        guard physical.contains(source) else {
            log.info("Source display \(source, privacy: .public) disappeared; restarting")
            restart()
            return
        }
        if let spec = Displays.modeSpec(for: source), spec != sourceSpec {
            log.info("Source mode changed to \(String(describing: spec), privacy: .public)")
            do {
                try await virtualDisplay.ensureDisplay(matching: spec)
                // A newer pass is queued and will pick up from here.
                guard !Task.isCancelled else { return }
                try await capture.updateConfiguration(spec: spec)
                sourceSpec = spec
                if preview.isVisible { showPreview() }
            } catch {
                log.error("Reconfigure failed: \(String(describing: error), privacy: .public)")
                restart()
                return
            }
        }
        virtualDisplay.park(physicalDisplayBounds: physical.map(CGDisplayBounds))
        showStage()
    }

    /// Refreshes run one at a time, and each reads the exclusion list only once it starts, so
    /// an older list can never be applied over a newer one.
    private func refreshFilter() {
        // A queued pass hasn't read the list yet, so it covers this request too.
        guard !isFilterRefreshQueued else { return }
        isFilterRefreshQueued = true
        let previous = filterTask
        filterTask = Task {
            await previous?.value
            isFilterRefreshQueued = false
            guard capture.isRunning else { return }
            do {
                try await capture.refreshFilter(policy: policy)
            } catch {
                log.error("Filter refresh failed: \(error.localizedDescription, privacy: .public)")
            }
            isFilterBehind = capture.mayShowApps(excludedBy: policy)
        }
    }

    /// A start builds its filter from the list as it was when the start began; the user may
    /// have excluded more apps while the stream was starting.
    private func checkFilterAfterStart() {
        isFilterBehind = capture.mayShowApps(excludedBy: policy)
        if isFilterBehind { refreshFilter() }
    }

    private func showStage() {
        stage.show(on: virtualDisplay.displayID.flatMap(Displays.screen(for:)))
    }

    private func showPreview() {
        guard let spec = sourceSpec else { return }
        preview.show(aspectRatio: CGSize(width: spec.pixelWidth, height: spec.pixelHeight))
    }
}
