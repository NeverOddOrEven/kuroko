/// Delays between capture restart attempts. Stream stops are usually transient, so the first
/// retry is quick.
public struct RetryBackoff: Sendable {
    public static let defaultDelays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(3)]

    private let delays: [Duration]
    private var attempt = 0

    public init(delays: [Duration] = defaultDelays) {
        precondition(!delays.isEmpty)
        self.delays = delays
    }

    public mutating func nextDelay() -> Duration {
        defer { attempt += 1 }
        return delays[min(attempt, delays.count - 1)]
    }

    public mutating func reset() {
        attempt = 0
    }
}

/// What to do after the capture failed to start.
public enum StartFailureResponse: Equatable, Sendable {
    /// Screen Recording is granted, but ScreenCaptureKit still declines this process. Retrying
    /// would re-show the system prompt and can't succeed; only a relaunch picks up the grant.
    case needsRelaunch
    case waitForPermission
    case retry

    public init(permissionDeclined: Bool, hasPermission: Bool) {
        switch (permissionDeclined, hasPermission) {
        case (true, true): self = .needsRelaunch
        case (_, false): self = .waitForPermission
        case (false, true): self = .retry
        }
    }
}
