import XCTest
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// The reducer, the coordinator and `AVPlayerEngine` together on a real `AVPlayer` playing an HLS stream **with a picture** (`HLSFixture.start(picture:)`):
/// the phases a stall, a jump and a swap of one stream for another take the state machine through, and whether the picture is the one the clock says
/// when they are over. (`CoordinatorOnHLSTests` has the same on the stream without one.)
@MainActor
final class CoordinatorOnHLSPictureTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .sdr)
    private let hi = QualityChoice(id: "hi", range: .sdr)
    private let lo = QualityChoice(id: "lo", range: .sdr)
    private let picture = HLSFixture.Picture()

    /// The probes of the items the provider made, one on each before it is on the player.
    private final class Probes {
        var all: [PictureProbe] = []
        var latest: PictureProbe? { all.last }
    }

    private func rig(
        segmentSeconds: TimeInterval = 2, options: AVPlayerEngine.Options = AVPlayerEngine.Options()
    ) async throws -> (rig: Rig, hls: HLSFixture, probes: Probes) {
        let hls = try await HLSFixture.start(seconds: 30, segmentSeconds: segmentSeconds, picture: picture)
        let rig = try Rig(options: options, makesFiles: false, recordsSelections: false)
        rig.files["film"] = hls.masterURL("hi")
        rig.files["film-lo"] = hls.masterURL("lo")
        rig.retained.append(hls)
        let probes = Probes()
        // (Taking the frames is what makes the player need the picture: see `Rig.itemMade`.)
        rig.itemMade = { probes.all.append(PictureProbe(item: $0, watches: true)) }
        return (rig, hls, probes)
    }

    private func assertPictureAgreesWithClock(_ rig: Rig, _ probe: PictureProbe, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        await rig.wait { probe.latest != nil }
        let shown = probe.latest
        XCTAssertEqual(Double(shown ?? -1), Double(picture.frame(at: rig.player.currentTime().seconds)), accuracy: 4, message, file: file, line: line)
    }

    func testAPictureThatRunsDryTakesThePhaseThroughBufferingAndBackToPlaying() async throws {
        let (rig, hls, probes) = try await rig()
        hls.holdVideoSegment(2)      // 4.0 .. 6.0 s
        rig.coordinator.load(film, quality: hi)
        let buffering = await rig.wait(timeout: 15) { rig.state.phase == .buffering }
        XCTAssertTrue(buffering, "phases: \(rig.phases)")
        XCTAssertEqual(rig.phases, [.loading, .playing, .buffering], "a start is not a stall, the dry run is")
        let probe = try XCTUnwrap(probes.latest)

        hls.releaseVideoSegment(2)
        let playing = await rig.waitUntilPlayingPast(hls.videoSegmentStart(2) + 0.6)
        XCTAssertTrue(playing, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.phases, [.loading, .playing, .buffering, .playing])
        await assertPictureAgreesWithClock(rig, probe, "and the picture is the clock's")
    }

    func testAJumpWithAPictureTakesThePhasesSeekingAndBackToPlayingAndShowsTheFrameOfTheTarget() async throws {
        let (rig, _, probes) = try await rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        let probe = try XCTUnwrap(probes.latest)
        rig.coordinator.seek(to: 20)
        XCTAssertEqual(rig.state.phase, .seeking)
        let playsOn = await rig.waitUntilPlayingPast(20.4)
        XCTAssertTrue(playsOn, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.phases, [.loading, .playing, .seeking, .playing])
        XCTAssertTrue(probe.seen.contains { abs($0 - picture.frame(at: 20)) <= 3 }, "the frame of the target was shown: \(probe.seen.suffix(20))")
        await assertPictureAgreesWithClock(rig, probe, "and the picture goes on with the clock")
    }

    func testAQualityChangeBetweenTwoStreamsWithAPictureKeepsThePlaybackGoingAndNeverBuffers() async throws {
        let (rig, hls, _) = try await rig()
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(1.2)
        let before = rig.state.position
        let phasesBefore = rig.phases.count
        rig.coordinator.requestQuality(lo)
        let done = await rig.wait { rig.state.quality == lo && rig.state.phase == .playing && rig.state.swap == nil }
        XCTAssertTrue(done, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(rig.playingURL?.path, hls.masterPath("lo"), "the other stream plays")
        XCTAssertEqual(Array(rig.phases.dropFirst(phasesBefore)), [.switching, .playing])
        // (The item that plays now is a copy of the prepared one, which a copy has no output of: it gets its own.)
        let probe = PictureProbe(item: try XCTUnwrap(rig.player.currentItem), watches: true)
        let moved = await rig.waitUntilPlayingPast(before + 0.8)
        XCTAssertTrue(moved, "it plays on from where it was, not from the start: \(rig.state.position) after \(before)")
        XCTAssertFalse(rig.phases.contains(.buffering), "phases: \(rig.phases)")
        await assertPictureAgreesWithClock(rig, probe, "the picture of the other stream, at the clock")
        XCTAssertGreaterThan(probe.seen.first ?? 0, picture.frame(at: before) - 6, "from where it was, not from frame 0: \(probe.seen.prefix(4))")
    }

    func testALoadAtAPositionThroughTheCoordinatorShowsNoFrameBeforeItWhenTheEngineTellsTheItemWhereToBegin() async throws {
        var first: [Bool: [Int]] = [:]
        for tells in [false, true] {
            let (rig, _, probes) = try await rig(options: .init(tellsItemWhereToBegin: tells))
            rig.coordinator.load(film, startAt: 20, quality: hi)
            let playing = await rig.waitUntilPlayingPast(20.6)
            XCTAssertTrue(playing, "option \(tells), phases: \(rig.phases), state: \(rig.state)")
            XCTAssertEqual(rig.phases, [.loading, .playing], "option \(tells): a start at a position is a start, whoever tells the item")
            let probe = try XCTUnwrap(probes.latest)
            await rig.wait { probe.latest != nil }
            first[tells] = probe.seen
            await assertPictureAgreesWithClock(rig, probe, "option \(tells): and the picture goes on with the clock")
        }
        XCTAssertEqual(first[false]?.first, 0, "control: without the option the opening frame is shown first: \(first[false]?.prefix(4) ?? [])")
        XCTAssertFalse(first[true]?.contains { $0 < picture.frame(at: 20) - 1 } == true, "no frame before the start position: \(first[true]?.prefix(4) ?? [])")
    }

    func testAReloadUnderTheViewerBeginsWhereItIsAskedToWhenTheEngineTellsTheItemWhereToBeginAndKeepsWhatTheViewerWanted() async throws {
        let (rig, _, probes) = try await rig(options: .init(tellsItemWhereToBegin: true))
        rig.coordinator.load(film, quality: hi)
        let playing = await rig.waitUntilPlayingPast(1.0)
        XCTAssertTrue(playing, "phases: \(rig.phases), state: \(rig.state)")
        rig.coordinator.reload(startAt: 20, quality: hi)
        let playsOn = await rig.waitUntilPlayingPast(20.6)
        XCTAssertTrue(playsOn, "phases: \(rig.phases), state: \(rig.state)")
        XCTAssertEqual(probes.all.count, 2, "the provider made a second item")
        XCTAssertTrue(rig.state.wantsPlay, "what the viewer wanted stays")
        let probe = try XCTUnwrap(probes.latest)
        XCTAssertFalse(probe.seen.contains { $0 < picture.frame(at: 20) - 1 }, "the new stream shows nothing from before the place it was asked to begin at: \(probe.seen.prefix(4))")
        XCTAssertFalse(rig.phases.contains(.buffering), "phases: \(rig.phases)")
        await assertPictureAgreesWithClock(rig, probe, "and the picture goes on with the clock")
    }

    func testACheapJumpIntoAPartThatIsNotLoadedLeavesTheStateAtTheTargetUntilTheNextTickAndThenAtWhereThePlayerIs() async throws {
        // This pins what is. `seekFinished` says that the jump landed, not where: the state keeps the target (15.6) until the next tick of the player,
        // which says 12.0 - the start of the segment the cheap jump landed at. Whoever shows `state.position` shows the bar jumping back by what the jump
        // saved; the engine of the car, which shows the player's own time, does not.
        let (rig, hls, _) = try await rig(segmentSeconds: 6, options: .init(jumps: .cheapest))
        hls.holdVideoSegment(2)      // 12.0 .. 18.0 s
        rig.coordinator.load(film, quality: hi)
        await rig.waitUntilPlayingPast(0.6)
        rig.coordinator.seek(to: 15.6)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(rig.state.phase, .seeking, "the jump waits for its picture")
        XCTAssertEqual(rig.state.position, 15.6, "and the screen shows where it goes")

        hls.releaseVideoSegment(2)
        let playing = await rig.wait { rig.state.phase == .playing }
        XCTAssertTrue(playing, "phases: \(rig.phases), state: \(rig.state)")
        let corrected = await rig.wait { rig.state.position < 14 }
        XCTAssertTrue(corrected, "the player is at the start of the segment, and the tick says so: \(rig.state.position)")
        XCTAssertEqual(rig.state.position, 12.0, accuracy: 1.2)
        XCTAssertEqual(rig.phases, [.loading, .playing, .seeking, .playing])
    }
}
