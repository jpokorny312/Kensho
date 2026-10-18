import XCTest
import AVFoundation
@testable import KenshoAVFoundation

final class StallWatchTests: XCTestCase {
    private typealias Step = (status: AVPlayer.TimeControlStatus, seek: Bool, at: TimeInterval)

    private func run(_ steps: [Step]) -> [StallWatch.Report?] {
        var watch = StallWatch()
        return steps.map { watch.observe($0.status, seekInFlight: $0.seek, now: $0.at) }
    }

    func testTheWaitAfterPlayIsAStartNotAStall() {
        XCTAssertEqual(run([(.waitingToPlayAtSpecifiedRate, false, 0), (.playing, false, 0.3)]), [nil, .recovered])
    }

    func testRunningDryAfterPlayingIsAStallAndGoingOnIsTheRecovery() {
        XCTAssertEqual(
            run([(.waitingToPlayAtSpecifiedRate, false, 0), (.playing, false, 0.3), (.waitingToPlayAtSpecifiedRate, false, 5), (.playing, false, 7)]),
            [nil, .recovered, .stalled, .recovered]
        )
    }

    func testEveryDryRunIsAStallAgain() {
        XCTAssertEqual(
            run([(.playing, false, 0), (.waitingToPlayAtSpecifiedRate, false, 1), (.playing, false, 2), (.waitingToPlayAtSpecifiedRate, false, 3)]),
            [.recovered, .stalled, .recovered, .stalled]
        )
    }

    func testWaitingDuringASeekIsTheSeek() {
        XCTAssertEqual(run([(.playing, false, 0), (.waitingToPlayAtSpecifiedRate, true, 1), (.playing, false, 2)]), [.recovered, nil, .recovered])
    }

    func testRunningDryAfterTheSeekLandedIsAStallAgain() {
        // A seek that did not change the status at all must not make the watch forget that the player was playing.
        XCTAssertEqual(run([(.playing, false, 0), (.playing, true, 1), (.waitingToPlayAtSpecifiedRate, false, 2)]), [.recovered, .recovered, .stalled])
    }

    func testWaitingAfterAPauseIsAStartAgain() {
        XCTAssertEqual(run([(.playing, false, 0), (.paused, false, 1), (.waitingToPlayAtSpecifiedRate, false, 2), (.playing, false, 2.3)]), [.recovered, nil, nil, .recovered])
    }

    func testPausingWhileWaitingIsNoStall() {
        XCTAssertEqual(run([(.waitingToPlayAtSpecifiedRate, false, 0), (.paused, false, 1)]), [nil, nil])
    }

    // MARK: - A start that does not get going

    func testAStartThatIsStillWaitingAfterTheGraceIsAStall() {
        var watch = StallWatch()
        XCTAssertNil(watch.observe(.paused, seekInFlight: false, now: 0))
        XCTAssertNil(watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 10))
        XCTAssertNil(watch.graceIsOver(now: 12.9), "not yet: three seconds")
        XCTAssertEqual(watch.graceIsOver(now: 13), .stalled, "the player did not get going: that is as much a thing to act on as one that broke off")
        XCTAssertNil(watch.graceIsOver(now: 20), "said once")
    }

    func testAStartThatGetsGoingInTimeIsNoStall() {
        var watch = StallWatch()
        _ = watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 10)
        XCTAssertEqual(watch.observe(.playing, seekInFlight: false, now: 10.4), .recovered)
        XCTAssertNil(watch.graceIsOver(now: 14), "it was playing since")
    }

    func testAStartThatWasPausedAgainIsNoStall() {
        var watch = StallWatch()
        _ = watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 10)
        _ = watch.observe(.paused, seekInFlight: false, now: 11)
        XCTAssertNil(watch.graceIsOver(now: 14))
    }

    func testAWaitThatWasAStallAlreadyIsNotCountedAgainByTheGrace() {
        var watch = StallWatch()
        _ = watch.observe(.playing, seekInFlight: false, now: 0)
        XCTAssertEqual(watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 5), .stalled)
        XCTAssertNil(watch.graceIsOver(now: 9))
    }

    func testTheWaitOfASeekIsNotAStartThatCounts() {
        var watch = StallWatch()
        _ = watch.observe(.paused, seekInFlight: false, now: 0)
        _ = watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: true, now: 1)
        XCTAssertNil(watch.graceIsOver(now: 9), "a jump that takes long is the jump's business")
    }
}
