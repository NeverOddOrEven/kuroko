import Foundation
import Testing
@testable import KurokoCore

struct App: RunningAppDescribing, Equatable {
    var bundleIdentifier: String
    var processID: pid_t
}

struct ExclusionPolicyTests {
    let slack = App(bundleIdentifier: "com.tinyspeck.slackmacgap", processID: 10)
    let safari = App(bundleIdentifier: "com.apple.Safari", processID: 11)
    let me = App(bundleIdentifier: "com.neveroddoreven.kuroko", processID: 99)

    @Test func excludesListedBundleIDs() {
        let policy = ExclusionPolicy(excludedBundleIDs: ["com.tinyspeck.slackmacgap"], selfProcessID: 99)
        #expect(policy.included(from: [slack, safari]) == [safari])
    }

    @Test func alwaysExcludesSelfEvenWithEmptyList() {
        let policy = ExclusionPolicy(excludedBundleIDs: [], selfProcessID: 99)
        #expect(policy.included(from: [safari, me]) == [safari])
    }

    @Test func appsMissingFromSnapshotAreNotIncluded() {
        // Fail-closed: the included list only ever contains apps present when it was built.
        let policy = ExclusionPolicy(excludedBundleIDs: [], selfProcessID: 99)
        let included = policy.included(from: [safari])
        #expect(!included.contains(slack))
    }

    @Test func addingAnExclusionExcludesMore() {
        let before = ExclusionPolicy(excludedBundleIDs: ["com.apple.Safari"], selfProcessID: 99)
        let after = ExclusionPolicy(excludedBundleIDs: ["com.apple.Safari", "com.tinyspeck.slackmacgap"], selfProcessID: 99)
        #expect(after.excludesMore(than: before))
        #expect(!before.excludesMore(than: after))
    }

    @Test func samePolicyDoesNotExcludeMore() {
        let policy = ExclusionPolicy(excludedBundleIDs: ["com.tinyspeck.slackmacgap"], selfProcessID: 99)
        #expect(!policy.excludesMore(than: policy))
    }

    @Test func swappingAnExclusionExcludesMore() {
        let slackOnly = ExclusionPolicy(excludedBundleIDs: ["com.tinyspeck.slackmacgap"], selfProcessID: 99)
        let safariOnly = ExclusionPolicy(excludedBundleIDs: ["com.apple.Safari"], selfProcessID: 99)
        #expect(safariOnly.excludesMore(than: slackOnly))
    }

    @Test func defaultsCoverSlackNotificationsAndTeams() {
        let ids = Set(ExclusionPolicy.defaultExcludedBundleIDs)
        #expect(ids.isSuperset(of: [
            "com.tinyspeck.slackmacgap",
            "com.apple.notificationcenterui",
            "com.microsoft.teams2",
        ]))
    }
}
