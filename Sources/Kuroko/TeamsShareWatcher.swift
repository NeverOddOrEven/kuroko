import AppKit
import KurokoCore

/// Watches for Teams sharing the Kuroko display and reports when that share ends.
@MainActor
final class TeamsShareWatcher {
    private static let teamsBundleIDs: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams"]

    var onShareEnded: () -> Void = {}

    private let displayBounds: () -> CGRect?
    private var timer: Timer?
    private var detector = ShareEndDetector()
    private var isSharing = false

    init(displayBounds: @escaping () -> CGRect?) {
        self.displayBounds = displayBounds
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        detector.reset()
        isSharing = false
    }

    private func check() {
        let teams = Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(Self.teamsBundleIDs.contains) ?? false }
            .map(\.processIdentifier))
        let sharing = if let bounds = displayBounds(), !teams.isEmpty {
            ShareDetection.isSharing(display: bounds, windows: Self.onScreenWindows(), sharerPIDs: teams)
        } else {
            false
        }
        if sharing != isSharing {
            isSharing = sharing
            log.info("Teams \(sharing ? "started" : "stopped", privacy: .public) sharing the Kuroko display")
        }
        if detector.update(isSharing: sharing, now: ProcessInfo.processInfo.systemUptime) {
            onShareEnded()
        }
    }

    private static func onScreenWindows() -> [WindowSnapshot] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return WindowSnapshot(ownerPID: pid, bounds: bounds, layer: layer)
        }
    }
}
