/// The contents of the Excluded Apps menu, separated from AppKit so they can be tested.
public enum ExclusionMenu {
    public struct App: Equatable, Sendable {
        public var bundleID: String
        public var name: String

        public init(bundleID: String, name: String) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    /// The excluded apps, then any defaults the user unchecked, so they're easy to re-enable.
    public static func listedBundleIDs(excluded: [String]) -> [String] {
        excluded + ExclusionPolicy.defaultExcludedBundleIDs.filter { !excluded.contains($0) }
    }

    /// Running apps that could be added to the list, sorted by name.
    public static func addableApps(running: [App], listed: [String], selfBundleID: String?) -> [App] {
        running
            .filter { !listed.contains($0.bundleID) && $0.bundleID != selfBundleID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
