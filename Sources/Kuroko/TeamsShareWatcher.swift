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
    private(set) var isSharing = false

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
        // Asking by bundle ID avoids fetching every running app's bundle ID twice a second.
        let teams = Set(Self.teamsBundleIDs
            .flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
            .map(\.processIdentifier))
        let sharing = if let bounds = displayBounds(), !teams.isEmpty {
            ShareDetection.isSharing(display: bounds, windows: WindowList.onScreen(), sharerPIDs: teams)
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
}
