import Foundation

/// Minimal view of a running app, so the policy can be tested without ScreenCaptureKit.
public protocol RunningAppDescribing {
    var bundleIdentifier: String { get }
    var processID: pid_t { get }
}

/// What the stage shows of the source display.
public enum CaptureMode: String, Sendable, CaseIterable {
    /// Everything except the excluded apps. An app launched later shows until it's excluded.
    case hideExcluded
    /// Only the desktop and the apps revealed since the display turned on. Anything else,
    /// including apps launched later, stays hidden (fail-closed).
    case showRevealed
}

/// Decides which apps are composited onto the stage.
///
/// In `.hideExcluded` mode the stream filter captures the whole display minus the excluded
/// apps' processes. An excluded app launched later isn't in the filter until the next refresh,
/// so the stage holds a frame from before its launch until the filter catches up.
public struct ExclusionPolicy: Sendable, Equatable {
    public static let defaultExcludedBundleIDs: [String] = [
        "com.tinyspeck.slackmacgap",       // Slack
        "com.apple.notificationcenterui",  // notification banners
        "com.microsoft.teams2",            // Teams (new)
        "com.microsoft.teams",             // Teams (classic)
    ]

    /// Shown in `.showRevealed` mode so viewers see the desktop rather than black.
    public static let desktopBundleIDs: Set<String> = ["com.apple.wallpaper.agent"]

    public var mode: CaptureMode
    public var excludedBundleIDs: Set<String>
    public var revealedBundleIDs: Set<String>
    /// Kuroko's own process; always excluded so the stage never captures itself.
    public var selfProcessID: pid_t

    public init(
        mode: CaptureMode = .hideExcluded,
        excludedBundleIDs: some Sequence<String>,
        revealedBundleIDs: some Sequence<String> = [String](),
        selfProcessID: pid_t
    ) {
        self.mode = mode
        self.excludedBundleIDs = Set(excludedBundleIDs)
        self.revealedBundleIDs = Set(revealedBundleIDs)
        self.selfProcessID = selfProcessID
    }

    public func isExcluded(_ app: some RunningAppDescribing) -> Bool {
        app.processID == selfProcessID || hides(bundleID: app.bundleIdentifier)
    }

    /// Whether an app with this bundle ID is kept off the stage (ignoring Kuroko itself).
    public func hides(bundleID: String) -> Bool {
        switch mode {
        case .hideExcluded: excludedBundleIDs.contains(bundleID)
        case .showRevealed: !revealedBundleIDs.contains(bundleID) && !Self.desktopBundleIDs.contains(bundleID)
        }
    }

    public func included<App: RunningAppDescribing>(from apps: [App]) -> [App] {
        apps.filter { !isExcluded($0) }
    }

    /// Whether this policy hides an app that `other` shows, so a filter built from `other`
    /// may leak something this policy excludes.
    public func excludesMore(than other: ExclusionPolicy) -> Bool {
        switch (mode, other.mode) {
        case (.hideExcluded, .hideExcluded):
            !excludedBundleIDs.isSubset(of: other.excludedBundleIDs)
        case (.showRevealed, .showRevealed):
            !other.revealedBundleIDs.isSubset(of: revealedBundleIDs)
        case (.showRevealed, .hideExcluded):
            // The other showed every app it didn't exclude.
            true
        case (.hideExcluded, .showRevealed):
            !other.revealedBundleIDs.isDisjoint(with: excludedBundleIDs)
        }
    }
}
