import Foundation

/// Persisted user settings.
public final class Preferences: @unchecked Sendable {
    private enum Key {
        static let sourceDisplayUUID = "sourceDisplayUUID"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let showPreview = "showPreview"
        static let frameRate = "frameRate"
        static let captureMode = "captureMode"
    }

    public static let frameRateOptions = [5, 15, 30, 60]
    public static let defaultFrameRate = 15

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// UUID string of the physical display to mirror; nil, or a display that isn't connected,
    /// means the main display.
    public var sourceDisplayUUID: String? {
        get { defaults.string(forKey: Key.sourceDisplayUUID) }
        set { defaults.set(newValue, forKey: Key.sourceDisplayUUID) }
    }

    public var excludedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.excludedBundleIDs) ?? ExclusionPolicy.defaultExcludedBundleIDs }
        set { defaults.set(newValue, forKey: Key.excludedBundleIDs) }
    }

    public func setExcluded(_ bundleID: String, _ excluded: Bool) {
        var ids = excludedBundleIDs.filter { $0 != bundleID }
        if excluded { ids.append(bundleID) }
        excludedBundleIDs = ids
    }

    public var captureMode: CaptureMode {
        get { defaults.string(forKey: Key.captureMode).flatMap(CaptureMode.init(rawValue:)) ?? .hideExcluded }
        set { defaults.set(newValue.rawValue, forKey: Key.captureMode) }
    }

    public var showPreview: Bool {
        get { defaults.bool(forKey: Key.showPreview) }
        set { defaults.set(newValue, forKey: Key.showPreview) }
    }

    /// Stage capture rate in frames per second; always one of `frameRateOptions`.
    public var frameRate: Int {
        get {
            let stored = defaults.integer(forKey: Key.frameRate)
            return Self.frameRateOptions.contains(stored) ? stored : Self.defaultFrameRate
        }
        set {
            guard Self.frameRateOptions.contains(newValue) else { return }
            defaults.set(newValue, forKey: Key.frameRate)
        }
    }
}
