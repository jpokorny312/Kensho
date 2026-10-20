import XCTest
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// The reducer, the coordinator and `AVPlayerEngine` together on a real `AVPlayer` playing an HLS stream from the loopback (`HLSFixture`): what the
/// state machine does with a stall that is a stall, a jump into a part that is not loaded, a swap of one stream for another and a track choice on the
/// groups of a real stream - the things `CoordinatorOnAVPlayerTests` cannot show on files.
@MainActor
final class CoordinatorOnHLSTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .sdr)
    private let hi = QualityChoice(id: "hi", range: .sdr)
    private let lo = QualityChoice(id: "lo", range: .sdr)

    private func rig(seconds: TimeInterval = 30) async throws -> (rig: Rig, hls: HLSFixture) {
        let hls = try await HLSFixture.start(seconds: seconds)
        // The engine's default applier: the choices go to the real groups of the stream.
        let rig = try Rig(makesFiles: false, recordsSelections: false)
        rig.files["film"] = hls.masterURL("hi")
        rig.files["film-lo"] = hls.masterURL("lo")
        rig.retained.append(hls)
        return (rig, hls)
    }

    private func tag(_ rig: Rig, _ characteristic: AVMediaCharacteristic) async throws -> String? {
        let item = try XCTUnwrap(rig.player.currentItem)
        let group = try await item.asset.loadMediaSelectionGroup(for: characteristic)
        return item.currentMediaSelection.selectedMediaOption(in: try XCTUnwrap(group))?.extendedLanguageTag
    }

    func testAStreamThatRunsDryTakesThePhaseThroughBufferingAndBackToPlaying() async throws {
        let (rig, hls) = try await rig()
        hls.holdSegment(2)      // 4.0 .. 6.0 s
        rig.coordinator.load(film, quality: hi)
        let buffering = await rig.wait(timeout: 15) { rig.state.phase == .buffering }
        XCTAssertTrue(buffering, "phases: \(rig.phases)")
        XCTAssertEqual(rig.phases, [.loading, .playing, .buffering], "a start is not a stall, the dry run is")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(rig.state.phase, .buffering, "and it stays one while the data is not there")

        hls.releaseSegment(2)
        let playing = await rig.waitUntilPlayingPast(hls.segmentStart(2) + 0.6)
        XCTAssertTrue(playing, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.phases, [.loading, .playing, .buffering, .playing])
        XCTAssertTrue(rig.state.wantsPlay)
    }

    func testAJumpIntoAPartThatIsNotLoadedKeepsThePhaseSeekingUntilItsDataComesAndNeverBuffers() async throws {
        let (rig, hls) = try await rig()
        hls.holdSegment(6)      // 12.0 .. 14.0 s
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        rig.coordinator.seek(to: 12.5)
        XCTAssertEqual(rig.state.phase, .seeking)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(rig.state.phase, .seeking, "the jump has not landed: its data is not there")
        XCTAssertEqual(rig.state.position, 12.5, "and the screen shows where it goes")

        hls.releaseSegment(6)
        let playsOn = await rig.waitUntilPlayingPast(13.1)
        XCTAssertTrue(playsOn, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.phases, [.loading, .playing, .seeking, .playing], "no stall in between: the wait was the jump's")
    }

    func testAQualityChangeBetweenTwoHLSStreamsKeepsThePlaybackGoingAndNeverBuffers() async throws {
        let (rig, hls) = try await rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(1.2)
        let before = rig.state.position
        let phasesBefore = rig.phases.count
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait { rig.state.quality == lo && rig.state.phase == .playing && rig.state.swap == nil }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.state.epoch, Epoch(2))
        XCTAssertEqual(rig.playingURL?.path, hls.masterPath("lo"), "the other stream plays")
        XCTAssertEqual(Array(rig.phases.dropFirst(phasesBefore)), [.switching, .playing])
        let moved = await rig.waitUntilPlayingPast(before + 0.6)
        XCTAssertTrue(moved, "it plays on from where it was, not from the start: \(rig.state.position) after \(before)")
        XCTAssertGreaterThan(rig.player.rate, 0)
        XCTAssertFalse(rig.phases.contains(.buffering), "phases: \(rig.phases)")
    }

    func testAQualityChangeWhilePausedBetweenTwoHLSStreamsStaysPaused() async throws {
        let (rig, hls) = try await rig()
        rig.coordinator.load(film, startAt: 8, quality: hi)
        await rig.waitUntilPlayingPast(8.6)
        rig.coordinator.pause()
        let held = rig.state.position
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait { rig.state.quality == lo && rig.state.phase == .paused && rig.state.swap == nil }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.playingURL?.path, hls.masterPath("lo"))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(rig.player.rate, 0)
        XCTAssertEqual(rig.player.currentTime().seconds, held, accuracy: 0.3, "the replacement began where the paused film stood")
    }

    func testTrackChoicesReachTheRealGroupsOfTheStream() async throws {
        let (rig, hls) = try await rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        let initialAudio = try await tag(rig, .audible), initialSubtitle = try await tag(rig, .legible)
        XCTAssertEqual(initialAudio, "en")
        XCTAssertNil(initialSubtitle)

        rig.coordinator.selectAudio(1)
        let german = await rig.wait { hls.server.requestedPaths.contains { $0.hasPrefix("/hi/audio-de/seg") } }
        XCTAssertTrue(german, "requests: \(hls.server.requestedPaths)")
        let audio = try await tag(rig, .audible)
        XCTAssertEqual(audio, "de")

        // A choice made while a jump is on its way waits for the landing, and is carried out after it.
        rig.coordinator.seek(to: 20)
        rig.coordinator.selectSubtitle(1)
        let shown = await rig.wait { hls.server.requestedPaths.contains(hls.subtitleSegmentPath(code: "de")) }
        XCTAssertTrue(shown, "phases: \(rig.phases), requests: \(hls.server.requestedPaths)")
        let subtitle = try await tag(rig, .legible)
        XCTAssertEqual(subtitle, "de")
        let playsOn = await rig.waitUntilPlayingPast(20.6)
        XCTAssertTrue(playsOn, "phases: \(rig.phases)")
        XCTAssertFalse(rig.phases.contains(.buffering), "neither the jump nor the choices were a stall: \(rig.phases)")

        rig.coordinator.selectSubtitle(nil)
        var off = false
        for _ in 0..<100 where !off {
            try await Task.sleep(nanoseconds: 20_000_000)
            off = try await tag(rig, .legible) == nil
        }
        XCTAssertTrue(off, "subtitles off")
    }

    func testTheEndOfAStreamLeavesTheStateMachinePausedAndWithoutAWishToPlay() async throws {
        // This pins what is: the model has no end, and the engine tells the stop of the player at the end of the item as the viewer's pause
        // (AVPlayerEngineHLSTests). The state machine is `paused` at the end with `wantsPlay` false - not `playing`, as it was thought to stay.
        let (rig, _) = try await rig(seconds: 4)
        rig.coordinator.load(film, quality: hi)
        let paused = await rig.wait(timeout: 12) { rig.state.phase == .paused }
        XCTAssertTrue(paused, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.phases, [.loading, .playing, .paused])
        XCTAssertFalse(rig.state.wantsPlay)
        let duration = try XCTUnwrap(rig.player.currentItem).duration.seconds
        XCTAssertEqual(rig.state.position, duration, accuracy: 0.7, "at the end")
    }
}
