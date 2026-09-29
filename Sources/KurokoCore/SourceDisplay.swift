import CoreGraphics

public enum SourceDisplay {
    /// The saved display if it's connected, else the main display, else the first one.
    public static func resolve(
        savedUUID: String?,
        displays: [(id: CGDirectDisplayID, uuid: String?)],
        mainID: CGDirectDisplayID
    ) -> CGDirectDisplayID {
        if let savedUUID, let saved = displays.first(where: { $0.uuid == savedUUID }) {
            return saved.id
        }
        let ids = displays.map(\.id)
        return ids.contains(mainID) ? mainID : (ids.first ?? mainID)
    }
}
