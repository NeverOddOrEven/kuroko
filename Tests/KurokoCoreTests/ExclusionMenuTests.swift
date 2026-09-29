import Testing
@testable import KurokoCore

struct ExclusionMenuTests {
    @Test func listsExcludedAppsThenUncheckedDefaults() {
        let listed = ExclusionMenu.listedBundleIDs(excluded: ["com.example.a", "com.microsoft.teams2"])
        #expect(listed == [
            "com.example.a",
            "com.microsoft.teams2",
            "com.tinyspeck.slackmacgap",
            "com.apple.notificationcenterui",
            "com.microsoft.teams",
        ])
    }

    @Test func addableAppsSkipListedAndSelfAndSortByName() {
        let running = [
            ExclusionMenu.App(bundleID: "com.example.zed", name: "zed"),
            ExclusionMenu.App(bundleID: "com.example.listed", name: "Listed"),
            ExclusionMenu.App(bundleID: "com.neveroddoreven.kuroko", name: "Kuroko"),
            ExclusionMenu.App(bundleID: "com.example.alpha", name: "Alpha"),
        ]
        let addable = ExclusionMenu.addableApps(
            running: running,
            listed: ["com.example.listed"],
            selfBundleID: "com.neveroddoreven.kuroko"
        )
        #expect(addable.map(\.name) == ["Alpha", "zed"])
    }
}
