import CoreGraphics
import Testing
@testable import KurokoCore

struct ShareDetectionTests {
    let display = CGRect(x: 1710, y: 1112, width: 1710, height: 1112)
    let teams: Set<pid_t> = [42]

    @Test func teamsOverlayCoveringTheDisplayIsSharing() {
        let overlay = WindowSnapshot(ownerPID: 42, bounds: display, layer: 2147483631)
        #expect(ShareDetection.isSharing(display: display, windows: [overlay], sharerPIDs: teams))
    }

    @Test func overlayMidAnimationStillCounts() {
        let bounds = CGRect(x: 1709, y: 1111, width: 1712, height: 1114)
        let overlay = WindowSnapshot(ownerPID: 42, bounds: bounds, layer: 2147483631)
        #expect(ShareDetection.isSharing(display: display, windows: [overlay], sharerPIDs: teams))
    }

    @Test func toolbarAloneIsNotSharing() {
        let toolbar = WindowSnapshot(ownerPID: 42, bounds: CGRect(x: 2170, y: 1142, width: 790, height: 55), layer: 24)
        #expect(!ShareDetection.isSharing(display: display, windows: [toolbar], sharerPIDs: teams))
    }

    @Test func otherAppsAndNormalWindowsAreNotSharing() {
        let otherApp = WindowSnapshot(ownerPID: 7, bounds: display, layer: 2147483631)
        let normal = WindowSnapshot(ownerPID: 42, bounds: display, layer: 0)
        #expect(!ShareDetection.isSharing(display: display, windows: [otherApp, normal], sharerPIDs: teams))
    }

    @Test func overlayOnAnotherDisplayIsNotSharing() {
        let overlay = WindowSnapshot(ownerPID: 42, bounds: CGRect(x: 0, y: 0, width: 1710, height: 1112), layer: 2147483631)
        #expect(!ShareDetection.isSharing(display: display, windows: [overlay], sharerPIDs: teams))
    }

    /// Feeds (isSharing, time) samples to a fresh detector and returns which ones reported an end.
    func ends(_ samples: [(Bool, Double)], resetAfter: Int? = nil) -> [Bool] {
        var detector = ShareEndDetector(grace: 1)
        return samples.enumerated().map { index, sample in
            if index == resetAfter { detector.reset() }
            return detector.update(isSharing: sample.0, now: sample.1)
        }
    }

    @Test func endIsReportedOnceAfterTheGracePeriod() {
        #expect(ends([(true, 0), (false, 0.5), (false, 1), (false, 2)]) == [false, false, true, false])
    }

    @Test func briefGapIsNotAnEnd() {
        #expect(ends([(true, 0), (false, 0.5), (true, 0.75), (false, 1.5), (false, 1.75)]) == [false, false, false, false, true])
    }

    @Test func nothingEndsWithoutAShare() {
        #expect(ends([(false, 0), (false, 5)]) == [false, false])
    }

    @Test func resetForgetsTheShare() {
        #expect(ends([(true, 0), (false, 2)], resetAfter: 1) == [false, false])
    }
}
