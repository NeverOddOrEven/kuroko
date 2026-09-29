import Foundation

/// Minimal view of a running app, so the policy can be tested without ScreenCaptureKit.
public protocol RunningAppDescribing {
    var bundleIdentifier: String { get }
    var processID: pid_t { get }
}

/// Decides which apps are composited onto the stage.
///
/// The stream filter captures the whole display minus the excluded apps' processes. An excluded
/// app launched later isn't in the filter until the next refresh, so the stage holds a frame
/// from before its launch until the filter catches up.
public struct ExclusionPolicy: Sendable, Equatable {
    public static let defaultExcludedBundleIDs: [String] = [
        "com.tinyspeck.slackmacgap",       // Slack
        "com.apple.notificationcenterui",  // notification banners
        "com.microsoft.teams2",            // Teams (new)
        "com.microsoft.teams",             // Teams (classic)
    ]

    public var excludedBundleIDs: Set<String>
    /// Kuroko's own process; always excluded so the stage never captures itself.
    public var selfProcessID: pid_t

    public init(excludedBundleIDs: some Sequence<String>, selfProcessID: pid_t) {
        self.excludedBundleIDs = Set(excludedBundleIDs)
        self.selfProcessID = selfProcessID
    }

    public func isExcluded(_ app: some RunningAppDescribing) -> Bool {
        app.processID == selfProcessID || excludedBundleIDs.contains(app.bundleIdentifier)
    }

    public func included<App: RunningAppDescribing>(from apps: [App]) -> [App] {
        apps.filter { !isExcluded($0) }
    }

    /// Whether this policy hides an app that `other` shows, so a filter built from `other`
    /// may leak something this policy excludes.
    public func excludesMore(than other: ExclusionPolicy) -> Bool {
        !excludedBundleIDs.isSubset(of: other.excludedBundleIDs)
    }
}
