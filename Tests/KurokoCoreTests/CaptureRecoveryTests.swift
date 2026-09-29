import Testing
@testable import KurokoCore

struct CaptureRecoveryTests {
    @Test func backoffStepsThroughDelaysThenRepeatsTheLast() {
        var backoff = RetryBackoff()
        let delays = (0..<5).map { _ in backoff.nextDelay() }
        #expect(delays == [.milliseconds(250), .seconds(1), .seconds(3), .seconds(3), .seconds(3)])
    }

    @Test func backoffResetStartsOver() {
        var backoff = RetryBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        #expect(backoff.nextDelay() == .milliseconds(250))
    }

    @Test(arguments: [
        (true, true, StartFailureResponse.needsRelaunch),
        (true, false, .waitForPermission),
        (false, false, .waitForPermission),
        (false, true, .retry),
    ])
    func startFailureResponse(declined: Bool, hasPermission: Bool, expected: StartFailureResponse) {
        #expect(StartFailureResponse(permissionDeclined: declined, hasPermission: hasPermission) == expected)
    }
}
