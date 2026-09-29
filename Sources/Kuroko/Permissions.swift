import AppKit
import CoreGraphics

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards it only returns the current state.
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    @MainActor
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Polls for the Screen Recording grant. Calling ScreenCaptureKit without permission re-shows
/// the system prompt on every call, so nothing touches it until the grant is visible.
@MainActor
final class PermissionWatcher {
    private var timer: Timer?

    func waitUntilGranted(_ onGranted: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        log.info("Waiting for Screen Recording permission")
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Permissions.hasScreenRecording else { return }
                self.cancel()
                log.info("Screen Recording permission granted")
                onGranted()
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
