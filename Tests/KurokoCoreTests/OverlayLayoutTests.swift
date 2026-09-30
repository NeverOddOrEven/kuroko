import CoreGraphics
import Testing
@testable import KurokoCore

struct OverlayLayoutTests {
    let display = CGRect(x: 100, y: 0, width: 1000, height: 800)
    let apps: [pid_t: String] = [1: "hidden.a", 2: "hidden.b", 3: "revealed"]

    func targets(_ windows: [WindowSnapshot]) -> [OverlayTarget] {
        OverlayLayout.targets(windows: windows, display: display, appID: { apps[$0] }, isHidden: { $0 != "revealed" })
    }

    func window(_ id: CGWindowID, _ pid: pid_t, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, layer: Int = 0) -> WindowSnapshot {
        WindowSnapshot(windowID: id, ownerPID: pid, bounds: CGRect(x: x, y: y, width: w, height: h), layer: layer)
    }

    @Test func hiddenAppsWindowsAreTargetedFrontToBack() {
        let result = targets([window(10, 1, 200, 100, 400, 300), window(11, 3, 200, 100, 400, 300), window(12, 2, 300, 200, 400, 300)])
        #expect(result.map(\.windowID) == [10, 12])
        #expect(result.map(\.appID) == ["hidden.a", "hidden.b"])
    }

    @Test func windowsKeepTheirGlobalBoundsAndLayer() {
        let result = targets([window(10, 1, 50, 100, 400, 300, layer: 3)])
        #expect(result.first?.bounds == CGRect(x: 50, y: 100, width: 400, height: 300))
        #expect(result.first?.layer == 3)
    }

    @Test func windowsOffTheDisplayAreSkipped() {
        #expect(targets([window(10, 1, 1200, 0, 400, 300)]).isEmpty)
    }

    @Test func menusTinySlicesAndUnknownOwnersAreSkipped() {
        let result = targets([
            window(10, 1, 200, 100, 400, 300, layer: 101),
            window(11, 1, 200, 100, 30, 300),
            window(12, 9, 200, 100, 400, 300),
        ])
        #expect(result.isEmpty)
    }

    @Test func promptGoesOnTheFrontmostWindowOfEachApp() {
        let result = targets([window(10, 1, 200, 100, 400, 300), window(11, 1, 200, 100, 600, 500), window(12, 2, 200, 100, 400, 300)])
        #expect(result.map(\.showsPrompt) == [true, false, true])
    }

    @Test func promptSkipsWindowsTooSmallForIt() {
        let result = targets([window(10, 1, 200, 100, 200, 100), window(11, 1, 200, 100, 600, 500)])
        #expect(result.map(\.showsPrompt) == [false, true])
    }

    @Test func promptFallsBackToTheFrontmostWindowWhenNoneFit() {
        let result = targets([window(10, 1, 200, 100, 200, 100), window(11, 1, 200, 100, 100, 100)])
        #expect(result.map(\.showsPrompt) == [true, false])
    }
}
