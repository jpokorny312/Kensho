import XCTest
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// The reducer, the coordinator and `AVPlayerEngine` together on a real
/// `AVPlayer` (muted, playing generated silence): what the state machine
/// decides must be what the player does, and what the player does must come back
/// as the state.
@MainActor
private final class Rig {
    let directory: URL
    let player = AVPlayer()
    private(set) var engine: AVPlayerEngine!
    private(set) var coordinator: PlaybackCoordinator!
    private(set) var phases: [Phase] = []
    private(set) var effects: [PlaybackEffect] = []
    private(set) var applied: [TrackSelection] = []
    /// The clock of the quality cooldown.
    var now: TimeInterval = 1_000
    var files: [String: URL] = [:]

    init() throws {
        directory = try TestMedia.makeDirectory()
        files["film"] = try TestMedia.silentAudio(seconds: 40, in: directory, name: "film")
        files["film-lo"] = try TestMedia.silentAudio(seconds: 40, in: directory, name: "film-lo")
        player.isMuted = true
        engine = AVPlayerEngine(
            player: player,
            provider: { [unowned self] source, quality in
                guard let url = self.files[quality.map { "\(source.id)-\($0.id)" } ?? source.id] ?? self.files[source.id] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return AVPlayerItem(url: url)
            },
            applier: { [unowned self] _, selection in self.applied.append(selection) }
        )
        coordinator = PlaybackCoordinator(engine: engine, clock: { [unowned self] in self.now })
        // The phases the film went through: a state change that only moved the position is not one.
        coordinator.onStateChange = { [unowned self] in if self.phases.last != $0.phase { self.phases.append($0.phase) } }
        coordinator.onTransition = { [unowned self] _, _, effects in self.effects.append(contentsOf: effects) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var state: PlaybackState { coordinator.state }
    var playingFile: String? { (player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent }

    @discardableResult
    func wait(timeout: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Where the viewer sees the playback: the state's position, fed by the engine's ticks.
    func waitUntilPlayingPast(_ position: TimeInterval) async -> Bool {
        await wait { self.state.phase == .playing && self.state.position > position }
    }
}

@MainActor
final class CoordinatorOnAVPlayerTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .sdr)
    private let hi = QualityChoice(id: "hi", range: .sdr)
    private let lo = QualityChoice(id: "lo", range: .sdr)

    func testALoadPlaysFromTheStartPositionAndThePositionFollows() async throws {
        let rig = try Rig()
        rig.coordinator.load(film, startAt: 5, quality: hi)
        let playing = await rig.waitUntilPlayingPast(5.8)
        XCTAssertTrue(playing, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.phases.prefix(2), [.loading, .playing])
        XCTAssertGreaterThan(rig.player.rate, 0)
        XCTAssertFalse(rig.phases.contains(.buffering), "a start is not a stall: \(rig.phases)")
    }

    func testPausingAndPlayingAgain() async throws {
        let rig = try Rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        rig.coordinator.pause()
        XCTAssertEqual(rig.state.phase, .paused)
        XCTAssertEqual(rig.player.rate, 0)
        let held = rig.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(rig.player.currentTime().seconds, held, accuracy: 0.05, "paused means paused")
        rig.coordinator.play()
        let playing = await rig.waitUntilPlayingPast(held + 0.6)
        XCTAssertTrue(playing, "phases: \(rig.phases)")
    }

    func testASeekWhilePlayingLandsAndPlaysOnFromThere() async throws {
        let rig = try Rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        rig.coordinator.seek(to: 25)
        XCTAssertEqual(rig.state.phase, .seeking)
        XCTAssertEqual(rig.state.position, 25, "the UI shows the target, not what the engine still says from before the jump")
        let playsOn = await rig.waitUntilPlayingPast(25.6)
        XCTAssertTrue(playsOn, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertFalse(rig.phases.contains(.buffering), "phases: \(rig.phases)")
    }

    func testASeekWhilePausedStaysPausedAfterItLanded() async throws {
        let rig = try Rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        rig.coordinator.pause()
        rig.coordinator.seek(to: 30)
        let landed = await rig.wait { rig.state.phase == .paused && rig.player.currentTime().seconds > 29.8 }
        XCTAssertTrue(landed, "phases: \(rig.phases), time: \(rig.player.currentTime().seconds)")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(rig.player.rate, 0, "the viewer had paused: the jump must not resume playback")
        XCTAssertEqual(rig.player.currentTime().seconds, 30, accuracy: 0.1)
    }

    func testAQualityChangeIsMadeWhilePlayingAndTakesOverWithoutLosingTheWay() async throws {
        let rig = try Rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(1.2)
        let before = rig.state.position
        let phasesBefore = rig.phases.count
        XCTAssertEqual(rig.phases.last, .playing)
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait { rig.state.quality == lo && rig.state.phase == .playing && rig.state.swap == nil }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.state.epoch, Epoch(2), "the replacement's session is the live one now")
        XCTAssertEqual(rig.playingFile, "film-lo.m4a")
        XCTAssertEqual(Array(rig.phases.dropFirst(phasesBefore)), [.switching, .playing], "the film never went back to loading or failed")
        let moved = await rig.waitUntilPlayingPast(before + 0.6)
        XCTAssertTrue(moved, "it plays on from where it was, not from the start: \(rig.state.position) after \(before)")
        XCTAssertGreaterThan(rig.state.position, before)
        XCTAssertGreaterThan(rig.player.rate, 0)
    }

    func testAQualityChangeWhilePausedTakesOverAndStaysPaused() async throws {
        let rig = try Rig()
        rig.coordinator.load(film, startAt: 8, quality: hi)
        await rig.waitUntilPlayingPast(8.6)
        rig.coordinator.pause()
        let held = rig.state.position
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait { rig.state.quality == lo && rig.state.phase == .paused && rig.state.swap == nil }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.playingFile, "film-lo.m4a")
        XCTAssertEqual(rig.player.rate, 0)
        XCTAssertEqual(rig.player.currentTime().seconds, held, accuracy: 0.3, "the replacement began where the paused film stood")
    }

    func testAJumpDuringTheMakingOfAReplacementIsHonouredBeforeItTakesOver() async throws {
        let rig = try Rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        rig.coordinator.requestQuality(lo)
        rig.coordinator.seek(to: 33)
        let done = await rig.wait { rig.state.quality == lo && rig.state.phase == .playing && rig.state.swap == nil && rig.state.position > 33 }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.playingFile, "film-lo.m4a")
        XCTAssertGreaterThan(rig.player.currentTime().seconds, 32.9, "the replacement took over from where the jump landed, not from before it")
    }

    func testAQualityThatCannotBeMadeLeavesThePlaybackUntouched() async throws {
        let rig = try Rig()
        rig.files["film-lo"] = nil
        rig.files["film-lo"] = rig.directory.appendingPathComponent("not-there.m4a")  // the item fails to load
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        rig.coordinator.requestQuality(lo)
        let settled = await rig.wait { rig.state.swap == nil }
        XCTAssertTrue(settled, "state: \(rig.state)")
        XCTAssertEqual(rig.state.phase, .playing)
        XCTAssertEqual(rig.state.quality, hi, "the quality did not change")
        XCTAssertEqual(rig.playingFile, "film.m4a")
        XCTAssertGreaterThan(rig.player.rate, 0)
    }

    func testTrackChoicesReachTheEngineAndAreHeldBackWhileSomethingIsInMotion() async throws {
        let rig = try Rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        rig.coordinator.selectAudio(1)
        let applied = await rig.wait { rig.applied.contains(TrackSelection(audio: 1)) }
        XCTAssertTrue(applied, "applied: \(rig.applied)")
        // Mid-seek the choice waits for the jump (it would race it), then it is applied once.
        rig.coordinator.seek(to: 20)
        rig.coordinator.selectSubtitle(2)
        XCTAssertFalse(rig.applied.contains(TrackSelection(audio: 1, subtitle: 2)), "held back while the jump is on its way")
        let later = await rig.wait { rig.applied.contains(TrackSelection(audio: 1, subtitle: 2)) }
        XCTAssertTrue(later, "applied: \(rig.applied), phases: \(rig.phases)")
    }

    func testAFilmThatCannotBeLoadedFails() async throws {
        let rig = try Rig()
        rig.files = [:]
        rig.coordinator.load(film, quality: hi)
        let failed = await rig.wait { if case .failed = rig.state.phase { return true } else { return false } }
        XCTAssertTrue(failed, "phases: \(rig.phases)")
    }

    func testStopEndsEverything() async throws {
        let rig = try Rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        rig.coordinator.requestQuality(lo)
        rig.coordinator.stop()
        XCTAssertEqual(rig.state.phase, .stopped)
        XCTAssertNil(rig.player.currentItem)
        let phases = rig.phases
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(rig.phases, phases, "nothing the engine says after the stop changes the state")
        XCTAssertNil(rig.player.currentItem, "a replacement that was on its way did not come back")
    }
}
