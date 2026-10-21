import XCTest
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// `AVPlayerEngine.Options.prebuffer`: a replacement that is made ready on a player of its own, loaded ahead of the running one, and takes over *as the
/// player* - on a real `AVPlayer`, playing an HLS stream with a picture whose frames carry their number (`PictureCode`), so that what the screen showed
/// can be read back (`ScreenLog`). The quality of the stream that is swapped to is served `delay` seconds late: a server that has to wake up for it.
@MainActor
final class AVPlayerEnginePrebufferTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .sdr)
    private let hi = QualityChoice(id: "hi", range: .sdr)
    private let lo = QualityChoice(id: "lo", range: .sdr)
    private let picture = HLSFixture.Picture()

    /// The lines the engine wrote.
    private final class Lines: LogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func write(_ line: String, tag: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    /// The changes of player the owner was told of, with what the two players were at that moment.
    private final class Changes {
        struct Change {
            var new: AVPlayer
            var old: AVPlayer
            var newTime: Double
            var oldTime: Double
        }
        var all: [Change] = []
    }

    private let lines = Lines()

    private func make(
        prebuffer: AVPlayerEngine.Options.Prebuffer? = .init(), follows: Bool = true, seconds: TimeInterval = 40, delay: TimeInterval = 0
    ) async throws -> (rig: Rig, hls: HLSFixture, screen: ScreenLog, changes: Changes) {
        let hls = try await HLSFixture.start(seconds: seconds, segmentSeconds: 2, picture: picture)
        let rig = try Rig(options: .init(prebuffer: prebuffer), makesFiles: false, recordsSelections: false, log: KenshoLog(sinks: [lines]))
        rig.files["film"] = hls.masterURL("hi")
        rig.files["film-lo"] = hls.masterURL("lo")
        rig.retained.append(hls)
        let screen = ScreenLog { rig.engine.player }
        rig.itemMade = { screen.register(PictureProbe(item: $0), for: $0) }
        let changes = Changes()
        if follows {
            rig.engine.onPlayerChange = { new, old in
                changes.all.append(.init(new: new, old: old, newTime: new.currentTime().seconds, oldTime: old.currentTime().seconds))
            }
        }
        hls.server.delay(prefix: "/lo/", by: delay)
        return (rig, hls, screen, changes)
    }

    private func url(of player: AVPlayer) -> URL? { (player.currentItem?.asset as? AVURLAsset)?.url }

    private func swapIsDone(_ rig: Rig) -> Bool { rig.state.quality == lo && rig.state.phase == .playing && rig.state.swap == nil }

    // MARK: - The hand-off

    func testAPrebufferedReplacementTakesOverAsThePlayerAndThePictureDoesNotStand() async throws {
        let (rig, hls, screen, changes) = try await make(delay: 0.5)
        let original = rig.engine.player
        rig.coordinator.load(film, quality: hi)
        let playing = await rig.waitUntilPlayingPast(3)
        XCTAssertTrue(playing, "phases: \(rig.phases)")
        let requested = ProcessInfo.processInfo.systemUptime
        let before = rig.state.position
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait(timeout: 30) { self.swapIsDone(rig) }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        let plays = await rig.waitUntilPlayingPast(rig.state.position + 2)
        XCTAssertTrue(plays, "and it goes on: \(rig.state)")
        screen.stop()

        XCTAssertEqual(changes.all.count, 1, "the owner was told once")
        XCTAssertTrue(rig.engine.player !== original, "the replacement's own player plays now")
        XCTAssertTrue(changes.all.first?.new === rig.engine.player && changes.all.first?.old === original)
        XCTAssertEqual(url(of: rig.engine.player)?.path, hls.masterPath("lo"), "the other stream")
        XCTAssertEqual(rig.phases, [.loading, .playing, .switching, .playing], "never buffering: the viewer saw the stream go on")
        let freeze = screen.freeze(after: requested)
        XCTAssertLessThan(freeze.seconds, 0.25, "the picture did not stand (a copy of the item stands for seconds here): \(freeze)")
        XCTAssertTrue(screen.discontinuities(after: requested).isEmpty, "and it went on from the frame it was at: \(screen.discontinuities(after: requested))")
        XCTAssertGreaterThan(rig.state.position, before + 2, "from where it was, not from the start")
        // the one stopped where the other began
        let change = try XCTUnwrap(changes.all.first)
        XCTAssertEqual(change.oldTime, change.newTime, accuracy: 0.08, "the running player was at the place the replacement began at")
        XCTAssertEqual(rig.engine.player.rate, 1, "the new player plays")
        // the old player is let go of
        let released = await rig.wait { original.currentItem == nil }
        XCTAssertTrue(released, "the old player has no item any more")
        XCTAssertEqual(original.rate, 0)
    }

    func testAReplacementThatIsSlowToLoadIsStillHandedOverWithoutAHoleAndTheLogSaysHowItWentFirstTime() async throws {
        let (rig, _, screen, changes) = try await make(delay: 1.0)
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        let requested = ProcessInfo.processInfo.systemUptime
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait(timeout: 40) { self.swapIsDone(rig) }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)\n\(lines.all.joined(separator: "\n"))")
        _ = await rig.waitUntilPlayingPast(rig.state.position + 2)
        screen.stop()
        XCTAssertEqual(changes.all.count, 1)
        XCTAssertLessThan(screen.freeze(after: requested).seconds, 0.25, "\(screen.freeze(after: requested))\n\(lines.all.joined(separator: "\n"))")
        XCTAssertFalse(rig.phases.contains(.buffering))
        let handOff = lines.all.first { $0.hasPrefix("hand-over at") }
        XCTAssertNotNil(handOff, "the log says where the hand-off was made: \(lines.all)")
        XCTAssertTrue(handOff?.contains("round 1") == true, "and that the first try was enough: \(handOff ?? "-")")
    }

    func testTheSameSwapWithoutThePrebufferStandsForSeconds() async throws {
        // The control: the measure sees a standing picture when there is one.
        let (rig, hls, screen, changes) = try await make(prebuffer: nil, delay: 0.5)
        let original = rig.engine.player
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        let requested = ProcessInfo.processInfo.systemUptime
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait(timeout: 30) { self.swapIsDone(rig) }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        _ = await rig.waitUntilPlayingPast(rig.state.position + 2)
        screen.stop()
        XCTAssertTrue(rig.engine.player === original, "the same player")
        XCTAssertTrue(changes.all.isEmpty)
        XCTAssertEqual(url(of: rig.engine.player)?.path, hls.masterPath("lo"))
        XCTAssertGreaterThan(screen.freeze(after: requested).seconds, 0.9, "a copy of the item on the running player stands while it fetches the media again")
    }

    func testTheReplacementIsNotReadyUntilItHasLoadedAndTheRunningPlayerPlaysOnMeanwhile() async throws {
        let (rig, hls, _, changes) = try await make()
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        hls.holdVideoSegment(5, variant: "lo")          // 10 to 12 s: the replacement cannot have the six seconds it asks for
        rig.coordinator.requestQuality(lo)
        let before = rig.state.position
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertNotNil(rig.state.swap, "still on its way")
        XCTAssertEqual(rig.state.phase, .playing, "the running stream plays on and is not interrupted")
        XCTAssertTrue(changes.all.isEmpty)
        XCTAssertGreaterThan(rig.state.position, before + 1.5, "it plays")

        hls.releaseVideoSegment(5, variant: "lo")
        let done = await rig.wait(timeout: 30) { self.swapIsDone(rig) }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(changes.all.count, 1)
        XCTAssertFalse(rig.phases.contains(.buffering), "phases: \(rig.phases)")
    }

    func testAReplacementThatDoesNotGetReadyInTimeIsGivenUpAndTheRunningPlayerGoesOn() async throws {
        let (rig, hls, _, changes) = try await make(prebuffer: .init(timeout: 2))
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        hls.holdVideoSegment(5, variant: "lo")
        rig.coordinator.requestQuality(lo)
        let gaveUp = await rig.wait(timeout: 10) { rig.state.swap == nil }
        XCTAssertTrue(gaveUp, "state: \(rig.state)")
        XCTAssertEqual(rig.state.quality, hi, "nothing changed")
        XCTAssertEqual(rig.state.phase, .playing)
        XCTAssertTrue(changes.all.isEmpty)
        let before = rig.state.position
        let moves = await rig.waitUntilPlayingPast(before + 1)
        XCTAssertTrue(moves, "the running player was not touched: \(rig.state)")
        XCTAssertFalse(rig.effects.contains { if case .commitSwap = $0 { return true } else { return false } })
    }

    func testAReplacementThatCannotBeLoadedLeavesTheRunningPlayerAlone() async throws {
        let (rig, hls, _, changes) = try await make()
        hls.server.fail("/lo/master.m3u8", status: 404)
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        rig.coordinator.requestQuality(lo)
        let gaveUp = await rig.wait(timeout: 15) { rig.state.swap == nil }
        XCTAssertTrue(gaveUp, "state: \(rig.state)")
        XCTAssertEqual(rig.state.quality, hi)
        XCTAssertEqual(rig.state.phase, .playing)
        XCTAssertTrue(changes.all.isEmpty)
    }

    // MARK: - What the viewer does meanwhile

    func testAPauseWhileTheReplacementTakesOverKeepsThePlaybackPausedOnTheNewPlayer() async throws {
        let (rig, hls, screen, changes) = try await make()
        let original = rig.engine.player
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        rig.coordinator.requestQuality(lo)
        let switching = await rig.wait(timeout: 30) { rig.state.phase == .switching }
        XCTAssertTrue(switching, "state: \(rig.state)")
        rig.coordinator.pause()
        let paused = await rig.wait(timeout: 15) { rig.state.phase == .paused && rig.state.swap == nil && !changes.all.isEmpty }
        XCTAssertTrue(paused, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertTrue(rig.engine.player !== original, "the replacement was handed over all the same")
        XCTAssertEqual(url(of: rig.engine.player)?.path, hls.masterPath("lo"))
        XCTAssertEqual(rig.engine.player.rate, 0, "and it does not play")
        XCTAssertEqual(original.rate, 0)
        let standing = rig.engine.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(rig.engine.player.currentTime().seconds, standing, accuracy: 0.05, "nothing moves")
        screen.stop()

        rig.coordinator.play()
        let plays = await rig.waitUntilPlayingPast(standing + 1)
        XCTAssertTrue(plays, "it goes on from there: \(rig.state)")
        XCTAssertEqual(rig.phases.suffix(3), [.switching, .paused, .playing])
    }

    func testAJumpWhileTheReplacementTakesOverLandsOnTheReplacement() async throws {
        let (rig, hls, _, changes) = try await make()
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        rig.coordinator.requestQuality(lo)
        let switching = await rig.wait(timeout: 30) { rig.state.phase == .switching }
        XCTAssertTrue(switching, "state: \(rig.state)")
        rig.coordinator.seek(to: 20)
        let plays = await rig.waitUntilPlayingPast(20.6)
        XCTAssertTrue(plays, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(changes.all.count, 1)
        XCTAssertEqual(url(of: rig.engine.player)?.path, hls.masterPath("lo"), "the jump was made on the replacement")
        XCTAssertEqual(Array(rig.phases.suffix(3)), [.switching, .seeking, .playing], "phases: \(rig.phases)")
    }

    func testStoppingWhileTheReplacementTakesOverLetsGoOfEverything() async throws {
        let (rig, _, screen, changes) = try await make()
        let original = rig.engine.player
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        rig.coordinator.requestQuality(lo)
        let switching = await rig.wait(timeout: 30) { rig.state.phase == .switching }
        XCTAssertTrue(switching, "state: \(rig.state)")
        rig.coordinator.stop()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        screen.stop()
        XCTAssertEqual(rig.state.phase, .stopped)
        XCTAssertTrue(changes.all.isEmpty, "nobody was handed anything")
        XCTAssertEqual(rig.engine.player.rate, 0)
        XCTAssertNil(rig.engine.player.currentItem)
        XCTAssertNil(original.currentItem)
        XCTAssertEqual(rig.phases.last, .stopped)
    }

    func testALoadWhileTheReplacementTakesOverStartsOverOnTheRunningPlayer() async throws {
        let (rig, hls, _, changes) = try await make()
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        rig.coordinator.requestQuality(lo)
        let switching = await rig.wait(timeout: 30) { rig.state.phase == .switching }
        XCTAssertTrue(switching, "state: \(rig.state)")
        rig.coordinator.load(film, startAt: 10, quality: hi)
        let plays = await rig.waitUntilPlayingPast(10.6)
        XCTAssertTrue(plays, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertTrue(changes.all.isEmpty, "the replacement that was thrown away was never handed over")
        XCTAssertEqual(url(of: rig.engine.player)?.path, hls.masterPath("hi"))
    }

    // MARK: - Other states of the running player

    func testAReplacementAskedForWhilePausedTakesOverPausedAndPlaysFromThere() async throws {
        let (rig, hls, _, changes) = try await make()
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        rig.coordinator.pause()
        let paused = await rig.wait { rig.state.phase == .paused }
        XCTAssertTrue(paused)
        let standing = rig.state.position
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait(timeout: 30) { rig.state.quality == self.lo && rig.state.phase == .paused && rig.state.swap == nil }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(changes.all.count, 1)
        XCTAssertEqual(rig.engine.player.rate, 0)
        XCTAssertEqual(rig.engine.player.currentTime().seconds, standing, accuracy: 0.6, "where it stood")
        XCTAssertEqual(url(of: rig.engine.player)?.path, hls.masterPath("lo"))
        rig.coordinator.play()
        let plays = await rig.waitUntilPlayingPast(standing + 1)
        XCTAssertTrue(plays, "state: \(rig.state)")
    }

    func testAReplacementTakesOverAPlayerThatRanDryAndTheStreamGoesOnWhereItStood() async throws {
        // The use that matters most: the stream is dying - this is what the swap is for.
        let (rig, hls, _, changes) = try await make()
        hls.holdVideoSegment(4)                                  // 8 to 10 s of the running stream
        rig.coordinator.load(film, quality: hi)
        let buffering = await rig.wait(timeout: 20) { rig.state.phase == .buffering }
        XCTAssertTrue(buffering, "phases: \(rig.phases), state: \(rig.state)")
        let standing = rig.engine.player.currentTime().seconds
        let requested = ProcessInfo.processInfo.systemUptime
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait(timeout: 30) { self.swapIsDone(rig) }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - requested, 8, "and not after the stream that is held is let go: it came with the replacement")
        XCTAssertEqual(changes.all.count, 1)
        XCTAssertEqual(url(of: rig.engine.player)?.path, hls.masterPath("lo"))
        let moves = await rig.waitUntilPlayingPast(standing + 1.5)
        XCTAssertTrue(moves, "it goes on from where it stood (\(standing)): \(rig.state)")
        XCTAssertGreaterThan(rig.engine.player.currentTime().seconds, standing - 0.5, "not from the start")
    }

    // MARK: - Owners that cannot follow

    func testWithoutAnOwnerThatFollowsThePlayerTheReplacementIsACopyOnTheRunningPlayer() async throws {
        let (rig, hls, _, _) = try await make(follows: false)
        let original = rig.engine.player
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait(timeout: 30) { self.swapIsDone(rig) }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertTrue(rig.engine.player === original, "an owner that is not told would look at a player that has stopped")
        XCTAssertEqual(url(of: original)?.path, hls.masterPath("lo"))
        XCTAssertEqual(rig.phases, [.loading, .playing, .switching, .playing])
    }

    // MARK: - More than one

    func testTwoSwapsInARowEachTakeOverAsThePlayerWithoutAHoleInThePicture() async throws {
        let (rig, hls, screen, changes) = try await make(seconds: 60)
        rig.coordinator.load(film, quality: hi)
        _ = await rig.waitUntilPlayingPast(3)
        let started = ProcessInfo.processInfo.systemUptime
        rig.coordinator.requestQuality(lo)
        let first = await rig.wait(timeout: 30) { self.swapIsDone(rig) }
        XCTAssertTrue(first, "phases: \(rig.phases), state: \(rig.state)")
        _ = await rig.waitUntilPlayingPast(rig.state.position + 2)
        rig.now += 100                                           // (the cooldown between two changes of quality)
        rig.coordinator.requestQuality(hi)
        let second = await rig.wait(timeout: 30) { rig.state.quality == self.hi && rig.state.phase == .playing && rig.state.swap == nil }
        XCTAssertTrue(second, "phases: \(rig.phases), state: \(rig.state)")
        _ = await rig.waitUntilPlayingPast(rig.state.position + 2)
        screen.stop()
        XCTAssertEqual(changes.all.count, 2)
        XCTAssertTrue(changes.all[1].old === changes.all[0].new, "the second hand-off is from the first replacement's player")
        XCTAssertEqual(url(of: rig.engine.player)?.path, hls.masterPath("hi"))
        XCTAssertLessThan(screen.freeze(after: started).seconds, 0.3, "\(screen.freeze(after: started))")
        XCTAssertTrue(screen.discontinuities(after: started).isEmpty, "\(screen.discontinuities(after: started))")
        XCTAssertFalse(rig.phases.contains(.buffering))
    }
}
