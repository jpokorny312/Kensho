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

    // MARK: - A place far ahead, a place that is not loaded, a jump that does not come back

    /// A hand-over aimed far ahead (the replacement is prepared at the place the running player will get to when the server's encoder has started - a few
    /// seconds from now, a few tens on a real server): the running player plays on, and the hand-over is made when it gets there - not before, not behind.
    func testAHandOverAimedFarAheadWaitsForTheRunningPlayerAndIsMadeWhenItGetsThere() async throws {
        let hls = try await fixture(seconds: 60)
        let (old, oldItem) = try await runningPlayer(on: hls)
        let target = old.currentTime().seconds + 7
        let staged = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: target, plan: plan)
        try await staged.prepare()
        let began = Date()
        var flippedAt: TimeInterval?
        var flippedAfter: TimeInterval?
        let outcome = await staged.handOver(
            from: old,
            aimedAt: target,
            isHeld: { false },
            isCurrent: { old.currentItem === oldItem },
            flip: { _ in
                flippedAt = old.currentTime().seconds
                flippedAfter = Date().timeIntervalSince(began)
            }
        )
        XCTAssertEqual(outcome, .handedOver)
        let at = try XCTUnwrap(flippedAt)
        XCTAssertEqual(at, target, accuracy: 0.5, "the running player had got to the place when the picture changed")
        XCTAssertGreaterThan(try XCTUnwrap(flippedAfter), 4, "it was waited for (the place was seven seconds ahead)")
        XCTAssertGreaterThan(staged.player.rate, 0)
        staged.cancel()
        old.pause()
    }

    /// The replacement was ready late: the running player is far past what it has loaded. That is not chased (a jump out of what is loaded is a fetch, and
    /// a running player outruns it: four rounds in 24 s on a real iPhone) - the owner is told at once, and the running player is left as it is.
    func testAPlaceThatIsNotLoadedIsNotChasedAndTheRunningPlayerIsLeftAlone() async throws {
        let hls = try await fixture(seconds: 60)
        let (old, oldItem) = try await runningPlayer(on: hls)
        // waits where the running player was five seconds ago: it has 6 s loaded from there, the running player is past that
        let staged = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: 0.5, plan: .init(bufferSeconds: 3, forwardBufferSeconds: 3, timeout: 20, waitsForFirstFrame: false))
        try await staged.prepare()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        _ = await old.seek(to: CMTime(seconds: 30, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(nanoseconds: 800_000_000)
        let began = Date()
        let outcome = await staged.handOver(from: old, isHeld: { false }, isCurrent: { old.currentItem === oldItem }, flip: { _ in XCTFail("nothing is handed over") })
        let took = Date().timeIntervalSince(began)
        guard case .failed = outcome else { return XCTFail("a place that is not loaded cannot be handed over to: \(outcome)") }
        XCTAssertLessThan(took, 6, "said at once, not after rounds of fetching")
        XCTAssertFalse(oldItem.forwardPlaybackEndTime.isValid, "the running item does not end anywhere")
        XCTAssertGreaterThan(old.rate, 0, "and the running player plays on")
        staged.cancel()
        old.pause()
    }

    /// A running player that is not going (paused, or waiting for data) a little before the place this player waits at: this player begins where it waits -
    /// it does not jump back out of what is loaded (the jump into a part that the server had not produced was the one that never came back).
    func testARunningPlayerThatStandsJustBeforeTheWaitingPlaceIsNotChasedBackwards() async throws {
        let hls = try await fixture(seconds: 60)
        let (old, oldItem) = try await runningPlayer(on: hls)
        old.pause()
        let stands = old.currentTime().seconds
        let staged = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: stands + 0.25, plan: plan)
        try await staged.prepare()
        var flipped = false
        let began = Date()
        let outcome = await staged.handOver(from: old, isHeld: { true }, isCurrent: { old.currentItem === oldItem }, flip: { playing in
            flipped = true
            XCTAssertFalse(playing, "the viewer holds it: it waits there")
        })
        XCTAssertEqual(outcome, .handedOver)
        XCTAssertTrue(flipped)
        XCTAssertLessThan(Date().timeIntervalSince(began), 3, "quick: nothing was fetched")
        XCTAssertEqual(staged.player.currentTime().seconds, stands + 0.25, accuracy: 0.1, "where it waited, not before it")
        staged.cancel()
    }

    /// The viewer pauses while the hand-over waits for a place some seconds ahead: the picture must not jump to the place (it would skip what the viewer has
    /// not seen) - the hand-over is not made, and the running player stays where the viewer paused it.
    func testAViewerWhoPausesWhileTheHandOverWaitsForAPlaceFarAheadIsNotSkippedAhead() async throws {
        let hls = try await fixture(seconds: 60)
        let (old, oldItem) = try await runningPlayer(on: hls)
        let target = old.currentTime().seconds + 14
        let staged = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: target, plan: plan)
        try await staged.prepare()
        var held = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            old.pause()
            held = true
        }
        let outcome = await staged.handOver(from: old, aimedAt: target, isHeld: { held }, isCurrent: { old.currentItem === oldItem }, flip: { _ in XCTFail("nothing is handed over") })
        guard case .failed = outcome else { return XCTFail("a pause before the place is no hand-over to the place: \(outcome)") }
        XCTAssertLessThan(old.currentTime().seconds, target - 5, "the running player stands where the viewer paused it")
        XCTAssertEqual(old.rate, 0)
        XCTAssertFalse(oldItem.forwardPlaybackEndTime.isValid)
        staged.cancel()
    }

    /// A jump that has to fetch from a server that does not answer never completes by itself (an HLS seek waits for its segment): it is cancelled after a
    /// few seconds and counts as no jump.
    func testAJumpOutOfWhatIsLoadedThatTheServerDoesNotAnswerIsGivenUp() async throws {
        let hls = try await fixture(seconds: 60)
        let staged = PrebufferedPlayer(item: AVPlayerItem(url: hls.masterURL("hi")), position: 5, plan: plan)
        try await staged.prepare()
        let farAway = hls.videoSegmentIndex(at: 40)
        for index in max(0, farAway - 2)...(farAway + 2) { hls.holdVideoSegment(index) }
        let began = Date()
        let aligned = await staged.align(to: 40, tail: 2, waits: 1)
        XCTAssertFalse(aligned, "nothing was there to jump to")
        XCTAssertLessThan(Date().timeIntervalSince(began), 12, "and the call came back")
        staged.cancel()
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
