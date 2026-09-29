import Foundation
import Testing
@testable import KurokoCore

/// Tests share one fixed suite, cleared around each test, so runs don't leave a plist behind
/// per test (cfprefsd keeps an empty file even after the domain is removed).
@Suite(.serialized)
final class PreferencesTests {
    private let suite = "KurokoTests"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func excludedAppsDefaultToPolicyDefaults() {
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.excludedBundleIDs == ExclusionPolicy.defaultExcludedBundleIDs)
    }

    @Test func roundTripsValues() {
        let prefs = Preferences(defaults: defaults)
        prefs.excludedBundleIDs = ["a.b.c"]
        prefs.sourceDisplayUUID = "UUID-1"
        prefs.showPreview = true
        #expect(prefs.excludedBundleIDs == ["a.b.c"])
        #expect(prefs.sourceDisplayUUID == "UUID-1")
        #expect(prefs.showPreview)
    }

    @Test func frameRateDefaultsTo30() {
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.frameRate == 30)
    }

    @Test func frameRateRoundTripsSupportedValues() {
        let prefs = Preferences(defaults: defaults)
        for fps in Preferences.frameRateOptions {
            prefs.frameRate = fps
            #expect(prefs.frameRate == fps)
        }
    }

    @Test func frameRateIgnoresUnsupportedValues() {
        let prefs = Preferences(defaults: defaults)
        prefs.frameRate = 60
        prefs.frameRate = 1000
        #expect(prefs.frameRate == 60)
        defaults.set(7, forKey: "frameRate")
        #expect(prefs.frameRate == Preferences.defaultFrameRate)
    }

    @Test func setExcludedAddsOnceAndRemoves() {
        let prefs = Preferences(defaults: defaults)
        prefs.excludedBundleIDs = ["a", "b"]
        prefs.setExcluded("c", true)
        prefs.setExcluded("c", true)
        #expect(prefs.excludedBundleIDs == ["a", "b", "c"])
        prefs.setExcluded("a", false)
        #expect(prefs.excludedBundleIDs == ["b", "c"])
    }

    @Test func emptyExclusionListIsPreserved() {
        let prefs = Preferences(defaults: defaults)
        prefs.excludedBundleIDs = []
        #expect(prefs.excludedBundleIDs.isEmpty)
    }
}
