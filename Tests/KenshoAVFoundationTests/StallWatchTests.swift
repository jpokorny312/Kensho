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
        XCTAssertNil(watch.graceIsOver(now: 12.9, seekInFlight: false), "not yet: three seconds")
        XCTAssertEqual(watch.graceIsOver(now: 13, seekInFlight: false), .stalled, "the player did not get going: that is as much a thing to act on as one that broke off")
        XCTAssertNil(watch.graceIsOver(now: 20, seekInFlight: false), "said once")
    }

    func testAStartThatGetsGoingInTimeIsNoStall() {
        var watch = StallWatch()
        _ = watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 10)
        XCTAssertEqual(watch.observe(.playing, seekInFlight: false, now: 10.4), .recovered)
        XCTAssertNil(watch.graceIsOver(now: 14, seekInFlight: false), "it was playing since")
    }

    func testAStartThatWasPausedAgainIsNoStall() {
        var watch = StallWatch()
        _ = watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 10)
        _ = watch.observe(.paused, seekInFlight: false, now: 11)
        XCTAssertNil(watch.graceIsOver(now: 14, seekInFlight: false))
    }

    func testAWaitThatWasAStallAlreadyIsNotCountedAgainByTheGrace() {
        var watch = StallWatch()
        _ = watch.observe(.playing, seekInFlight: false, now: 0)
        XCTAssertEqual(watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 5), .stalled)
        XCTAssertNil(watch.graceIsOver(now: 9, seekInFlight: false))
    }

    func testTheWaitOfASeekIsNotAStartThatCounts() {
        var watch = StallWatch()
        _ = watch.observe(.paused, seekInFlight: false, now: 0)
        _ = watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: true, now: 1)
        XCTAssertNil(watch.graceIsOver(now: 9, seekInFlight: true), "a jump that takes long is the jump's business")
    }

    // MARK: - A wait that outlasts a jump

    func testAWaitThatGoesOnAfterTheJumpHasLandedIsAStartFromThen() {
        var watch = StallWatch()
        _ = watch.observe(.playing, seekInFlight: false, now: 0)
        XCTAssertNil(watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: true, now: 5), "during the jump: the jump's wait")
        XCTAssertNil(watch.graceRemaining(now: 6), "nothing is counted while the jump is on its way")
        watch.seekLanded(now: 8)
        XCTAssertEqual(watch.graceRemaining(now: 8), 3, "the player still waits for its first data at the new place: a start")
        XCTAssertNil(watch.graceIsOver(now: 10.9, seekInFlight: false))
        XCTAssertEqual(watch.graceIsOver(now: 11, seekInFlight: false), .stalled, "and a start that does not get going is a stall")
    }

    func testAJumpThatLandsOnAPlayerThatPlaysCountsNothing() {
        var watch = StallWatch()
        _ = watch.observe(.playing, seekInFlight: false, now: 0)
        watch.seekLanded(now: 4)
        XCTAssertNil(watch.graceRemaining(now: 4))
    }

    func testTheGraceIsNotLostWhenItIsAskedEarly() {
        // The clock of the check and the sleep of the task that asks are not the same clock (the device may have slept): early is not "never".
        var watch = StallWatch()
        _ = watch.observe(.paused, seekInFlight: false, now: 0)
        _ = watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 10)
        XCTAssertNil(watch.graceIsOver(now: 11, seekInFlight: false))
        XCTAssertEqual(try XCTUnwrap(watch.graceRemaining(now: 11)), 2, accuracy: 0.001, "it says how long to wait still")
        XCTAssertEqual(watch.graceIsOver(now: 13, seekInFlight: false), .stalled)
    }

    func testAGraceThatRunsOutWhileAJumpIsOnItsWayIsNotSpent() {
        var watch = StallWatch()
        _ = watch.observe(.paused, seekInFlight: false, now: 0)
        _ = watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 10)
        // The viewer jumps at 12; at 13 the check comes: the state machine is `seeking` and would drop a stall, which would then never be said again.
        XCTAssertNil(watch.graceIsOver(now: 13, seekInFlight: true))
        XCTAssertNil(watch.graceRemaining(now: 13), "it is the jump's wait now")
        watch.seekLanded(now: 14)
        XCTAssertEqual(watch.graceIsOver(now: 17, seekInFlight: false), .stalled, "counted from the landing")
    }

    // MARK: - A wait that the engine's own change of the track causes

    func testTheWaitRightAfterATrackChangeIsAStartFromThenAndNotAStall() {
        var watch = StallWatch()
        _ = watch.observe(.playing, seekInFlight: false, now: 0)
        watch.trackChanged(now: 5)
        // AVPlayer drops what it had of the old audio and waits for the new one: the choice of the viewer, not a weak link.
        XCTAssertNil(watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 5.05))
        XCTAssertEqual(watch.graceRemaining(now: 5.05), 3, "it counts like a start")
        XCTAssertEqual(watch.observe(.playing, seekInFlight: false, now: 5.1), .recovered)
        XCTAssertNil(watch.graceRemaining(now: 5.1), "and the new track plays")
    }

    func testAWaitOfATrackChangeThatLastsTheGraceIsAStallAfterAll() {
        var watch = StallWatch()
        _ = watch.observe(.playing, seekInFlight: false, now: 0)
        watch.trackChanged(now: 5)
        _ = watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 5.05)
        XCTAssertNil(watch.graceIsOver(now: 8.04, seekInFlight: false))
        XCTAssertEqual(watch.graceIsOver(now: 8.05, seekInFlight: false), .stalled, "the other track does not come: that is as much a thing to act on as a start that does not")
    }

    func testRunningDryLongAfterATrackChangeIsAStallRightAway() {
        var watch = StallWatch()
        _ = watch.observe(.playing, seekInFlight: false, now: 0)
        watch.trackChanged(now: 5)
        XCTAssertEqual(
            watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 5 + StallWatch.trackChangeWindow + 0.1), .stalled,
            "the change has nothing to do with this one"
        )
    }

    func testATrackChangeOnAPlayerThatAlreadyStalledAddsNoSecondReport() {
        var watch = StallWatch()
        _ = watch.observe(.playing, seekInFlight: false, now: 0)
        XCTAssertEqual(watch.observe(.waitingToPlayAtSpecifiedRate, seekInFlight: false, now: 1), .stalled)
        watch.trackChanged(now: 2)
        XCTAssertNil(watch.graceRemaining(now: 2))
        XCTAssertNil(watch.graceIsOver(now: 9, seekInFlight: false))
    }
}
