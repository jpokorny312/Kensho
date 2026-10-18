import XCTest
import AVFoundation
@testable import KenshoAVFoundation

final class StallWatchTests: XCTestCase {
    private func run(_ steps: [(AVPlayer.TimeControlStatus, seek: Bool)]) -> [StallWatch.Report?] {
        var watch = StallWatch()
        return steps.map { watch.observe($0.0, seekInFlight: $0.seek) }
    }

    func testTheWaitAfterPlayIsAStartNotAStall() {
        XCTAssertEqual(run([(.waitingToPlayAtSpecifiedRate, false), (.playing, false)]), [nil, .recovered])
    }

    func testRunningDryAfterPlayingIsAStallAndGoingOnIsTheRecovery() {
        XCTAssertEqual(
            run([(.waitingToPlayAtSpecifiedRate, false), (.playing, false), (.waitingToPlayAtSpecifiedRate, false), (.playing, false)]),
            [nil, .recovered, .stalled, .recovered]
        )
    }

    func testEveryDryRunIsAStallAgain() {
        XCTAssertEqual(
            run([(.playing, false), (.waitingToPlayAtSpecifiedRate, false), (.playing, false), (.waitingToPlayAtSpecifiedRate, false)]),
            [.recovered, .stalled, .recovered, .stalled]
        )
    }

    func testWaitingDuringASeekIsTheSeek() {
        XCTAssertEqual(run([(.playing, false), (.waitingToPlayAtSpecifiedRate, true), (.playing, false)]), [.recovered, nil, .recovered])
    }

    func testRunningDryAfterTheSeekLandedIsAStallAgain() {
        // A seek that did not change the status at all must not make the watch forget that the player was playing.
        XCTAssertEqual(run([(.playing, false), (.playing, true), (.waitingToPlayAtSpecifiedRate, false)]), [.recovered, .recovered, .stalled])
    }

    func testWaitingAfterAPauseIsAStartAgain() {
        XCTAssertEqual(run([(.playing, false), (.paused, false), (.waitingToPlayAtSpecifiedRate, false), (.playing, false)]), [.recovered, nil, nil, .recovered])
    }

    func testPausingWhileWaitingIsNoStall() {
        XCTAssertEqual(run([(.waitingToPlayAtSpecifiedRate, false), (.paused, false)]), [nil, nil])
    }
}
