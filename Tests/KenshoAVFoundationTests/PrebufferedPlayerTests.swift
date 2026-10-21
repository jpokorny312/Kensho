import XCTest
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// `PrebufferedPlayer` by itself: an HLS stream from the loopback, brought to the place where a hand-off can be made without a wait.
@MainActor
final class PrebufferedPlayerTests: XCTestCase {
    private let plan = PrebufferedPlayer.Plan(bufferSeconds: 6, forwardBufferSeconds: 8, timeout: 20, waitsForFirstFrame: false)

    private func fixture(variants: [String] = ["hi"], seconds: TimeInterval = 40) async throws -> HLSFixture {
        try await HLSFixture.start(seconds: seconds, segmentSeconds: 2, variants: variants, picture: HLSFixture.Picture())
    }

    func testItIsReadyAtItsPositionWithTheBufferLoadedAndThePlayerSilentAndStill() async throws {
        let hls = try await fixture()
        let prebuffered = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: 10, plan: plan)
        try await prebuffered.prepare()
        XCTAssertEqual(prebuffered.item.status, .readyToPlay)
        XCTAssertEqual(prebuffered.player.currentTime().seconds, 10, accuracy: 0.05, "it waits where it was told to")
        XCTAssertGreaterThanOrEqual(prebuffered.bufferedAhead(from: 10), 6, "six seconds are loaded from there")
        XCTAssertEqual(prebuffered.player.rate, 0)
        XCTAssertTrue(prebuffered.player.isMuted)
        XCTAssertFalse(prebuffered.player.automaticallyWaitsToMinimizeStalling, "preroll and a start on the host clock need that")
        XCTAssertFalse(hls.server.requestedPaths.contains(hls.videoSegmentPath(0)), "nothing before its position was asked for (the item was told where to begin)")
        prebuffered.cancel()
    }

    func testItDoesNotLoadFarBeyondWhatAHandOffCanNeed() async throws {
        let hls = try await fixture(seconds: 60)
        let prebuffered = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: 10, plan: plan)
        try await prebuffered.prepare()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let loaded = try XCTUnwrap(prebuffered.loaded)
        XCTAssertLessThan(loaded.upperBound, 10 + 6 + 8 + 4.5, "the forward buffer is the plan's: \(loaded)")
        prebuffered.cancel()
    }

    func testAJumpInsideWhatIsLoadedIsQuickAndLeavesTheTailLoaded() async throws {
        let hls = try await fixture()
        let prebuffered = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: 10, plan: plan)
        try await prebuffered.prepare()
        let began = ProcessInfo.processInfo.systemUptime
        let aligned = await prebuffered.align(to: 12.4, tail: 2)
        let took = ProcessInfo.processInfo.systemUptime - began
        XCTAssertTrue(aligned)
        XCTAssertLessThan(took, 0.5, "a few frames of work, not a fetch")
        XCTAssertEqual(prebuffered.player.currentTime().seconds, 12.4, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(prebuffered.bufferedAhead(from: 12.4), 2)
        XCTAssertEqual(prebuffered.position, 12.4)
        prebuffered.cancel()
    }

    func testAJumpOutsideWhatIsLoadedWaitsForTheStreamToBeLoadedThere() async throws {
        let hls = try await fixture()
        let prebuffered = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: 5, plan: plan)
        try await prebuffered.prepare()
        let aligned = await prebuffered.align(to: 30, tail: 2)
        XCTAssertTrue(aligned)
        XCTAssertGreaterThanOrEqual(prebuffered.bufferedAhead(from: 30), 2)
        XCTAssertEqual(prebuffered.player.currentTime().seconds, 30, accuracy: 0.05)
        prebuffered.cancel()
    }

    func testItGivesUpWhenTheStreamDoesNotComeInTime() async throws {
        let hls = try await fixture()
        hls.holdVideoSegment(6)                                  // 12 s on: the six seconds from 10 can not be loaded
        let prebuffered = PrebufferedPlayer(
            item: AVPlayerItem(url: hls.masterURL("hi")), position: 10, plan: .init(bufferSeconds: 6, forwardBufferSeconds: 8, timeout: 2, waitsForFirstFrame: false)
        )
        do {
            try await prebuffered.prepare()
            XCTFail("it can not be ready")
        } catch let failure as PrebufferedPlayer.Failure {
            guard case .timedOut = failure else { return XCTFail("\(failure)") }
        }
        prebuffered.cancel()
    }

    func testItSaysSoWhenTheStreamCanNotBeLoadedAtAll() async throws {
        let hls = try await fixture()
        hls.server.fail("/hi/master.m3u8", status: 404)
        let prebuffered = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: 10, plan: plan)
        do {
            try await prebuffered.prepare()
            XCTFail("it can not be ready")
        } catch let failure as PrebufferedPlayer.Failure {
            guard case .itemFailed = failure else { return XCTFail("\(failure)") }
        }
        prebuffered.cancel()
    }

    func testCancellingStopsTheLoadingAndLetsGoOfTheItem() async throws {
        let hls = try await fixture(seconds: 60)
        let item = AVPlayerItem(url: hls.masterURL("hi"))
        let prebuffered = PrebufferedPlayer(item: item, position: 10, plan: plan)
        try await prebuffered.prepare()
        prebuffered.cancel()
        try await Task.sleep(nanoseconds: 500_000_000)
        let asked = hls.server.requests.count
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(hls.server.requests.count, asked, "nothing is asked for any more")
        XCTAssertNil(prebuffered.player.currentItem)
    }

    // MARK: - The hand-over itself

    /// A running player on the fixture's stream, playing for a few seconds already.
    private func runningPlayer(on hls: HLSFixture) async throws -> (player: AVPlayer, item: AVPlayerItem) {
        let item = AVPlayerItem(url: hls.masterURL("hi"))
        let player = AVPlayer(playerItem: item)
        player.play()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !(player.currentTime().seconds > 3 && player.timeControlStatus == .playing) { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThan(player.currentTime().seconds, 3, "the running player plays")
        return (player, item)
    }

    /// The main actor is busy when the hand-over is due (a view that is drawn, a burst of work): the wake-up is late, the old item has reached its end
    /// by then. The old item pauses at its end and stays the player's item, so the hand-over is late - not lost.
    func testAWakeUpThatIsLateFindsTheOldItemAtItsEndAndTheHandOverIsMadeLate() async throws {
        let hls = try await fixture(seconds: 60)
        let (old, oldItem) = try await runningPlayer(on: hls)
        XCTAssertEqual(old.actionAtItemEnd, .pause, "the default of an AVPlayer: the item stays at its end")
        let staged = PrebufferedPlayer.beside(old, item: AVPlayerItem(url: hls.masterURL("hi")), startAt: 0)
        try await staged.prepare()
        var flipped = false
        var blocked = false
        let outcome = await staged.handOver(
            from: old,
            isHeld: { false },
            isCurrent: { old.currentItem === oldItem },
            log: { _ in
                // The main actor is taken a moment after the hand-over was timed, and for longer than it has to wait (0.8 s of the running player).
                if !blocked {
                    blocked = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        Thread.sleep(forTimeInterval: 1.4)
                    }
                }
            },
            flip: { _ in flipped = true }
        )
        XCTAssertEqual(outcome, .handedOver, "late, not lost")
        XCTAssertTrue(flipped)
        XCTAssertTrue(old.currentItem === oldItem, "the old item was still the running player's when the flip was made")
        XCTAssertGreaterThan(staged.player.rate, 0, "the new player plays")
        staged.cancel()
        old.pause()
    }

    /// A hand-over that is called off after the old item was told to end at the place (the connection changed, a newer instruction): the old item plays on
    /// past the place - it must not stop there for good.
    func testACalledOffHandOverGivesTheRunningItemItsEndBack() async throws {
        let hls = try await fixture(seconds: 60)
        let (old, oldItem) = try await runningPlayer(on: hls)
        let staged = PrebufferedPlayer.beside(old, item: AVPlayerItem(url: hls.masterURL("hi")), startAt: 0)
        try await staged.prepare()
        var calledOff = false
        var place = 0.0
        let outcome = await staged.handOver(
            from: old,
            isHeld: { false },
            isCurrent: { !calledOff },
            log: { line in
                calledOff = true
                // "hand-over at 12.34 s: ..."
                place = line.components(separatedBy: "hand-over at ").last?.components(separatedBy: " s").first.flatMap(Double.init) ?? 0
            },
            flip: { _ in XCTFail("nothing is handed over") }
        )
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(oldItem.forwardPlaybackEndTime.isValid, "the old item does not end at the place any more")
        staged.cancel()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, old.currentTime().seconds < place + 1.5 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertGreaterThan(old.currentTime().seconds, place + 1, "the old item plays on past the place the hand-over was timed for")
        XCTAssertGreaterThan(old.rate, 0)
        old.pause()
    }

    /// The next episode: another stream on a timeline of its own. The running player plays on while the other is made ready (the viewer sees the credits,
    /// not a black picture); at the cut it stops and the other begins where it waits, at once.
    func testACutOverBeginsTheOtherStreamWhereItWaitsAndStopsTheRunningOne() async throws {
        let oldStream = try await fixture(seconds: 60)
        let nextEpisode = try await fixture(seconds: 60)
        let (old, _) = try await runningPlayer(on: oldStream)
        let before = old.currentTime().seconds
        let staged = PrebufferedPlayer(item: AVPlayerItem(url: nextEpisode.masterURL("hi")), position: 0, plan: plan)
        try await staged.prepare()
        XCTAssertGreaterThan(old.currentTime().seconds, before, "the running player went on while the other was made ready")
        XCTAssertEqual(staged.player.rate, 0, "and the other waits")
        var flipped = false
        let outcome = await staged.cutOver(from: old, isCurrent: { true }, flip: { flipped = true })
        XCTAssertEqual(outcome, .handedOver)
        XCTAssertTrue(flipped)
        XCTAssertEqual(old.rate, 0, "the running player stopped")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, staged.player.currentTime().seconds < 0.8 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThan(staged.player.currentTime().seconds, 0.8, "the other plays from where it waited")
        XCTAssertLessThan(staged.player.currentTime().seconds, 3.0, "and it began at the cut, not before")
        XCTAssertGreaterThan(staged.player.rate, 0)
        staged.cancel()
    }

    /// A cut that is called off at the last moment (another episode was chosen meanwhile) leaves the running player as it is.
    func testACutOverThatIsCalledOffLeavesTheRunningPlayerAlone() async throws {
        let oldStream = try await fixture(seconds: 60)
        let nextEpisode = try await fixture(seconds: 60)
        let (old, oldItem) = try await runningPlayer(on: oldStream)
        let staged = PrebufferedPlayer(item: AVPlayerItem(url: nextEpisode.masterURL("hi")), position: 0, plan: plan)
        try await staged.prepare()
        let outcome = await staged.cutOver(from: old, isCurrent: { false }, flip: { XCTFail("nothing is handed over") })
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(old.currentItem === oldItem)
        XCTAssertGreaterThan(old.rate, 0, "the running player plays on")
        XCTAssertEqual(staged.player.rate, 0, "and the other still waits")
        staged.cancel()
        old.pause()
    }

    func testCancellingWhileItIsBeingMadeReadyEndsThePreparation() async throws {
        let hls = try await fixture()
        hls.holdVideoSegment(6)
        let prebuffered = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: 10, plan: plan)
        let task = Task { try await prebuffered.prepare() }
        try await Task.sleep(nanoseconds: 800_000_000)
        prebuffered.cancel()
        do {
            try await task.value
            XCTFail("a cancelled preparation is not ready")
        } catch let failure as PrebufferedPlayer.Failure {
            XCTAssertEqual(failure, .cancelled)
        }
    }
}
