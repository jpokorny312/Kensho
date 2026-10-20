import XCTest
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// `AVPlayerEngine` against a real `AVPlayer` playing an HLS stream **with a picture** from the loopback (`HLSFixture.start(picture:)`): H.264 in segments
/// of its own, a keyframe every two seconds, the number of the frame drawn into it (`PictureProbe` reads it from what the player shows). What the stream
/// without a picture could not show: where a jump lands when there are keyframes, and whether the picture is the one the clock says, after a jump, a
/// stall, a change of the audio and a swap of one stream for another.
///
/// Frame N is the picture at N/24 s. The stream is 30 s long; its picture is in segments of 2 s (a segment is one group of pictures) or, where the test
/// says so, of 6 s (three keyframes in a segment). The audio has segments of about that length, but not exactly (AAC frames do not divide a second:
/// `hls.segmentStart` is the audio's, `hls.videoSegmentStart` the picture's).
@MainActor
final class AVPlayerEngineHLSPictureTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .sdr)
    private let none = TrackSelection()
    private let lo = QualityChoice(id: "lo", range: .sdr)
    private let picture = HLSFixture.Picture()

    /// The probes of the items the provider made, in order - one for each item, put on it before it is on a player.
    private final class Probes {
        var all: [PictureProbe] = []
        var latest: PictureProbe? { all.last }
    }

    /// A flag a KVO or completion callback may set from wherever AVFoundation calls it.
    private final class Flag: @unchecked Sendable { var isSet = false }

    private func rig(
        seconds: TimeInterval = 30, segmentSeconds: TimeInterval = 2, options: AVPlayerEngine.Options = AVPlayerEngine.Options()
    ) async throws -> (h: EngineHarness, hls: HLSFixture, probes: Probes) {
        let hls = try await HLSFixture.start(seconds: seconds, segmentSeconds: segmentSeconds, picture: picture)
        let h = try EngineHarness(options: options)
        let probes = Probes()
        h.make = { [unowned hls] _, quality in
            let item = AVPlayerItem(url: hls.masterURL(quality?.id ?? "hi"))
            probes.all.append(PictureProbe(item: item, watches: true))
            return item
        }
        h.retained.append(hls)
        return (h, hls, probes)
    }

    /// Loads (paused at `startAt`) and waits until the engine says it is ready.
    private func load(_ h: EngineHarness, startAt: TimeInterval = 0, selection: TrackSelection = TrackSelection()) async -> Bool {
        h.engine.perform(.load(Epoch(1), film, startAt: startAt, selection: selection, quality: nil))
        return await h.waitFor(.engineReady(Epoch(1)))
    }

    /// A line of the numbers behind `Docs/Zusammenfuehrung.md`, printed when `KENSHO_MEASURE` is set: `KENSHO_MEASURE=1 swift test --filter AVPlayerEngineHLSPictureTests`.
    private func measured(_ line: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["KENSHO_MEASURE"] != nil { print("MEASURED: \(line())") }
    }

    private func isFailure(_ event: PlaybackEvent) -> Bool { if case .engineFailed = event { return true } else { return false } }

    private func withoutTicks(_ events: [PlaybackEvent]) -> [PlaybackEvent] { events.filter { if case .engineTick = $0 { return false } else { return true } } }

    private func path(of item: AVPlayerItem?) -> String? { (item?.asset as? AVURLAsset)?.url.path }

    /// Waits until the probe has a frame, and gives its number.
    private func frame(_ h: EngineHarness, _ probe: PictureProbe) async -> Int? {
        await h.wait(timeout: 5) { probe.poll() != nil }
        return probe.latest
    }

    // MARK: - Where a jump lands

    private enum Jump: String {
        /// The engine with `Options.jumps = .exact` (the default).
        case engineExact
        /// The engine with `Options.jumps = .cheapest`.
        case engineCheapest
        /// `player.seek(to:)` of an `AVPlayer` of its own: how the old engine of the car jumped.
        case plainSeek
        /// The same with the tolerance written out.
        case infiniteTolerance
    }

    private struct Landing: CustomStringConvertible {
        var time: TimeInterval
        var frame: Int?
        var videoSegmentStart: TimeInterval
        var audioSegmentStart: TimeInterval
        var keyframeBefore: TimeInterval?
        var keyframeAfter: TimeInterval?
        var description: String { "landed at \(time), frame \(frame.map(String.init) ?? "none") (the segment of the picture begins at \(videoSegmentStart), the audio's at \(audioSegmentStart); keyframes \(String(describing: keyframeBefore)) | \(String(describing: keyframeAfter)))" }
    }

    /// One jump on a player of its own. `loaded` says whether the part of the stream the target is in has been fetched when the jump is made; if it has
    /// not, the segment of the picture that holds the target is kept back until the jump has waited for it (a small stream is fetched whole within a
    /// second, so a part that is not loaded has to be one that cannot be).
    private func landing(of jump: Jump, to target: TimeInterval, segmentSeconds: TimeInterval, loaded: Bool) async throws -> Landing {
        let engine = jump == .engineExact || jump == .engineCheapest
        let (h, hls, probes) = try await rig(segmentSeconds: segmentSeconds, options: .init(jumps: jump == .engineCheapest ? .cheapest : .exact))
        let videoSegment = hls.videoSegmentIndex(at: target), audioSegment = hls.segmentIndex(at: target)
        if !loaded { hls.holdVideoSegment(videoSegment) }

        var player = h.player
        var probe: PictureProbe
        if engine {
            let ready = await load(h)
            XCTAssertTrue(ready, "\(jump): \(h.events)")
            probe = try XCTUnwrap(probes.latest)
        } else {
            player = AVPlayer()
            player.isMuted = true
            let item = AVPlayerItem(url: hls.masterURL())
            probe = PictureProbe(item: item, watches: true)
            player.replaceCurrentItem(with: item)
            let ready = await h.wait { item.status == .readyToPlay }
            XCTAssertTrue(ready, "\(jump): \(String(describing: item.error))")
        }
        if loaded {
            let fetched = await h.wait {
                hls.server.answeredPaths.contains(hls.videoSegmentPath(videoSegment)) && hls.server.answeredPaths.contains(hls.segmentPath(audio: "en", audioSegment))
            }
            XCTAssertTrue(fetched, "\(jump): the part is loaded (else this test shows nothing): \(hls.server.answeredPaths)")
        }
        probe.forget()

        let time = CMTime(seconds: target, preferredTimescale: 600)
        let landed = Flag()
        switch jump {
        case .engineExact, .engineCheapest:
            h.engine.perform(.seek(Epoch(1), SeekToken(1), to: target))
        case .plainSeek:
            player.seek(to: time) { _ in landed.isSet = true }
        case .infiniteTolerance:
            player.seek(to: time, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) { _ in landed.isSet = true }
        }
        let hasLanded = { engine ? h.events.contains(.seekFinished(Epoch(1), SeekToken(1))) : landed.isSet }
        if !loaded {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            XCTAssertFalse(hasLanded(), "\(jump): the jump waits for its data (else this test shows nothing)")
            hls.releaseVideoSegment(videoSegment)
        }
        let done = await h.wait { hasLanded() }
        XCTAssertTrue(done, "\(jump): \(h.events)")
        let shown = await frame(h, probe)
        let keyframes = hls.keyframes(around: target)
        let result = Landing(
            time: player.currentTime().seconds, frame: shown, videoSegmentStart: hls.videoSegmentStart(videoSegment),
            audioSegmentStart: hls.segmentStart(audioSegment), keyframeBefore: keyframes.before, keyframeAfter: keyframes.after
        )
        measured("jump \(jump) to \(target) in segments of \(segmentSeconds) s, part \(loaded ? "loaded" : "not loaded"): \(result)")
        return result
    }

    func testAJumpIntoAPartThatIsNotLoadedLandsOnTheTargetWhenExactAndAtTheStartOfItsSegmentWhenCheapNeverAtAKeyframeInsideIt() async throws {
        // 15.6 s: in a segment of 2 s that begins at 14.0 (its keyframe); in a segment of 6 s that begins at 12.0, with keyframes at 14.0 and 16.0 inside.
        for segmentSeconds in [2.0, 6.0] {
            let label = "segments of \(segmentSeconds) s"
            let exact = try await landing(of: .engineExact, to: 15.6, segmentSeconds: segmentSeconds, loaded: false)
            XCTAssertEqual(exact.time, 15.6, accuracy: 0.05, "\(label), exact: \(exact)")
            XCTAssertEqual(Double(exact.frame ?? -1), Double(picture.frame(at: 15.6)), accuracy: 1, "\(label), exact: the picture is the frame of the target")

            var cheap: [Jump: Landing] = [:]
            for jump in [Jump.engineCheapest, .plainSeek, .infiniteTolerance] {
                let result = try await landing(of: jump, to: 15.6, segmentSeconds: segmentSeconds, loaded: false)
                cheap[jump] = result
                // The beginning of the segment (give or take the few milliseconds by which the audio's segment begins later) ...
                XCTAssertEqual(result.time, result.videoSegmentStart, accuracy: 0.05, "\(label), \(jump): \(result)")
                if segmentSeconds > 2 {
                    // ... and nowhere in it: not at the keyframe before the target, not at the one after it.
                    XCTAssertGreaterThan(abs(result.time - (result.keyframeBefore ?? 0)), 1, "\(label), \(jump): \(result)")
                    XCTAssertGreaterThan(abs(result.time - (result.keyframeAfter ?? 0)), 1, "\(label), \(jump): \(result)")
                }
                // ... and the picture is the frame of the clock there, a keyframe or not: nothing is shown that the clock does not say.
                XCTAssertEqual(Double(result.frame ?? -1), Double(picture.frame(at: result.time)), accuracy: 2, "\(label), \(jump): \(result)")
            }
            // What the old engine of the car did and what `.cheapest` asks for are one thing.
            let reference = try XCTUnwrap(cheap[.plainSeek]).time
            for (jump, result) in cheap { XCTAssertEqual(result.time, reference, accuracy: 0.01, "\(label), \(jump) lands where the plain seek lands") }
            XCTAssertLessThan(reference, 15.6 - 0.5, "\(label): a cheap jump into a part that is not loaded lands before the target")
        }
    }

    func testEveryKindOfJumpIntoALoadedPartLandsOnTheTargetAndShowsItsFrame() async throws {
        // The cheap jump is cheap only where it saves a fetch: a part that is there is landed on exactly, whatever the tolerance.
        for segmentSeconds in [2.0, 6.0] {
            for jump in [Jump.engineExact, .engineCheapest, .plainSeek, .infiniteTolerance] {
                let result = try await landing(of: jump, to: 15.6, segmentSeconds: segmentSeconds, loaded: true)
                XCTAssertEqual(result.time, 15.6, accuracy: 0.05, "segments of \(segmentSeconds) s, \(jump): \(result)")
                XCTAssertEqual(Double(result.frame ?? -1), Double(picture.frame(at: 15.6)), accuracy: 1, "segments of \(segmentSeconds) s, \(jump): \(result)")
            }
        }
    }

    func testAJumpWhilePlayingIntoAPartOfThePictureThatIsNotThereYetIsNeitherAStallNorLandedBeforeItsDataComes() async throws {
        let (h, hls, probes) = try await rig()
        hls.holdVideoSegment(6)      // 12.0 .. 14.0 s of the picture; the audio is there
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.8 }
        let probe = try XCTUnwrap(probes.latest)
        h.clearEvents()

        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 12.5))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(h.player.timeControlStatus, .waitingToPlayAtSpecifiedRate, "the player waits for the picture (else this test shows nothing)")
        XCTAssertFalse(h.events.contains(.seekFinished(Epoch(1), SeekToken(1))), "the jump has not landed: its picture is not there")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "the wait of a jump is the jump: \(withoutTicks(h.events))")

        hls.releaseVideoSegment(6)
        let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(1)))
        XCTAssertTrue(landed, "events: \(withoutTicks(h.events))")
        XCTAssertEqual(h.player.currentTime().seconds, 12.5, accuracy: 0.2)
        let playsOn = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 13.3 }
        XCTAssertTrue(playsOn, "and plays on from there")
        probe.poll()
        XCTAssertEqual(Double(probe.latest ?? -1), Double(picture.frame(at: h.player.currentTime().seconds)), accuracy: 3)
        XCTAssertTrue(probe.seen.contains { abs($0 - picture.frame(at: 12.5)) <= 2 }, "the frame of the target was shown: \(probe.seen.suffix(30))")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "nor was the start from the new place one: \(withoutTicks(h.events))")
    }

    // MARK: - A start

    func testAStartPositionIsReachedOnTheFrameAndNotAtTheKeyframeBefore() async throws {
        let (h, _, probes) = try await rig()
        let ready = await load(h, startAt: 13)      // the keyframe is at 12.0
        XCTAssertTrue(ready, "events: \(h.events)")
        // (The probe looks every ten milliseconds from the main run loop; one full run in a busy machine failed here - load average 10, the test passed alone three
        // times and in the next full run - with the frame not yet in `seen`, probably because the timer had not come round yet. Looking now asks what the player has
        // ready now, which is what "on the player when the engine said ready" means; a frame that is not there is still a failure.)
        probes.latest?.poll()
        measured("start at 13 s: when the engine said ready the probe had seen \(probes.latest?.seen ?? [])")
        XCTAssertTrue(
            probes.latest?.seen.contains { abs($0 - picture.frame(at: 13)) <= 1 } == true,
            "the picture of the start position was on the player when the engine said ready - no black screen after 'ready': \(probes.latest?.seen ?? [])"
        )
        XCTAssertEqual(h.player.currentTime().seconds, 13, accuracy: 0.05)
        XCTAssertEqual(h.player.rate, 0)
        let probe = try XCTUnwrap(probes.latest)
        let shown = await frame(h, probe)
        XCTAssertEqual(Double(shown ?? -1), Double(picture.frame(at: 13)), accuracy: 1, "the picture waiting at the start is frame \(picture.frame(at: 13)), not the keyframe's 288")
        // What was on the screen before it: an item that has not been told where to begin starts at its first frame, and shows it until the jump lands
        // (measured: `[0, 312, 313, ...]`). The engine says `engineReady` when the jump has landed; a view that shows the picture sooner shows that frame.
        XCTAssertTrue(probe.seen.prefix { $0 < picture.frame(at: 13) - 1 }.allSatisfy { $0 == 0 }, "nothing but the opening frame before the start position, the keyframe's 288 least of all: \(probe.seen.prefix(6))")
        h.engine.perform(.play(Epoch(1)))
        let playsOn = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 13.6 }
        XCTAssertTrue(playsOn)
        probe.poll()
        XCTAssertEqual(Double(probe.latest ?? -1), Double(picture.frame(at: h.player.currentTime().seconds)), accuracy: 3, "and the picture goes on with the clock")
    }

    func testStartingAtAPositionFetchesTheBeginningOfTheStreamFirstAndShowsItsOpeningFrameWhereAnItemToldWhereToBeginDoesNot() async throws {
        // This pins what is, not what should be. The engine puts the item on the player, waits until it is ready and jumps; AVPlayer has started at 0
        // by then, and fetches the first segments and shows the first frame before the jump arrives. An item that is told where to begin before it
        // loads (what the car's way of starting does - the provider's `item.seek`) fetches nothing of the beginning and shows no frame before the position.
        // Measured on 2026-10-19/20 on a stream of 60 s (video and audio segments 0 to 4 or 6 fetched first, then those from 16 on; frames [0, 792] against
        // [792]); the cost on a source that makes its segments on request - PrismCore - is not measured.
        var fetchedFirst: [Bool] = []
        var framesSeen: [[Int]] = []
        for told in [false, true] {
            let (h, hls, probes) = try await rig(seconds: 60, options: .init(startsPlayingAtOnce: told))
            if told {
                h.make = { [unowned hls] _, _ in
                    let item = AVPlayerItem(url: hls.masterURL("hi"))
                    item.seek(to: CMTime(seconds: 33, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
                    probes.all.append(PictureProbe(item: item, watches: true))
                    return item
                }
            }
            h.engine.perform(.load(Epoch(1), film, startAt: 33, selection: none, quality: nil))
            if told { h.engine.perform(.pause(Epoch(1))) }      // (a car's engine plays; the picture is what is looked at here)
            let ready = await h.waitFor(.engineReady(Epoch(1)))
            XCTAssertTrue(ready, "told \(told): \(h.events)")
            try await Task.sleep(nanoseconds: 400_000_000)
            let probe = try XCTUnwrap(probes.latest)
            fetchedFirst.append(hls.server.requestedPaths.contains(hls.videoSegmentPath(0)))
            framesSeen.append(Array(probe.seen.prefix(3)))
        }
        XCTAssertEqual(fetchedFirst, [true, false], "the segment at the beginning of the stream is fetched when the engine jumps, and not when the item was told where to begin")
        XCTAssertEqual(framesSeen[0].first, 0, "the opening frame is shown first when the engine jumps: \(framesSeen[0])")
        XCTAssertFalse(framesSeen[1].contains(0), "and not when the item was told: \(framesSeen[1])")
        XCTAssertEqual(Double(framesSeen[1].first ?? -1), Double(picture.frame(at: 33)), accuracy: 2)
    }

    func testStartingToPlayAStreamWithAPictureIsNoStall() async throws {
        let (h, _, probes) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.clearEvents()
        h.engine.perform(.play(Epoch(1)))
        let playing = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 1.5 }
        XCTAssertTrue(playing, "events: \(h.events.suffix(6))")
        // (The decoder has its start to make as well as the audio: the wait after `play()` is longer than the audio's, and it is a start.)
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "events: \(withoutTicks(h.events))")
        let probe = try XCTUnwrap(probes.latest)
        probe.poll()
        XCTAssertGreaterThan(probe.latest ?? 0, 30, "and the picture is there")
    }

    // MARK: - A stall

    func testAPictureThatRunsDryWhilePlayingIsAStallThatEndsWithItsDataAndThePictureGoesOn() async throws {
        let (h, hls, probes) = try await rig()
        hls.holdVideoSegment(2)      // 4.0 .. 6.0 s of the picture; the audio is all there
        let ready = await load(h)
        XCTAssertTrue(ready, "events: \(h.events)")
        let probe = try XCTUnwrap(probes.latest)
        h.engine.perform(.play(Epoch(1)))

        let stalled = await h.waitFor(.engineStalled(Epoch(1)), timeout: 15)
        XCTAssertTrue(stalled, "events: \(withoutTicks(h.events))")
        let dryAt = h.player.currentTime().seconds
        XCTAssertEqual(dryAt, 4.0, accuracy: 0.3, "it ran dry where the picture ends, though the audio goes on")
        XCTAssertEqual(h.player.timeControlStatus, .waitingToPlayAtSpecifiedRate)
        probe.poll()
        let standing = probe.latest
        measured("picture held back at 4.0 s: engineStalled with the clock at \(dryAt), the picture standing at frame \(standing.map(String.init) ?? "none")")
        XCTAssertEqual(Double(standing ?? -1), Double(picture.frame(at: 4.0)), accuracy: 3, "and the last picture is the last frame there is")

        try await Task.sleep(nanoseconds: 1_200_000_000)
        let stallIndex = try XCTUnwrap(h.events.lastIndex(of: .engineStalled(Epoch(1))))
        XCTAssertEqual(h.stalls(of: Epoch(1)), 1, "said once: \(h.events.suffix(8))")
        XCTAssertFalse(h.events[stallIndex...].contains(.engineRecovered(Epoch(1))))
        XCTAssertEqual(h.player.currentTime().seconds, dryAt, accuracy: 0.05, "the position stood still")
        probe.poll()
        XCTAssertEqual(probe.latest, standing, "and so did the picture")

        hls.releaseVideoSegment(2)
        let recovered = await h.wait { h.events[stallIndex...].contains(.engineRecovered(Epoch(1))) }
        XCTAssertTrue(recovered, "events: \(h.events.suffix(8))")
        let playsOn = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 4.8 }
        XCTAssertTrue(playsOn, "through the part that was kept back")
        probe.poll()
        XCTAssertEqual(Double(probe.latest ?? -1), Double(picture.frame(at: h.player.currentTime().seconds)), accuracy: 3, "with the picture of the clock")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 1)
    }

    func testTheAudioRunningDryUnderAPictureThatIsThereIsAStallAsWell() async throws {
        let (h, hls, probes) = try await rig()
        hls.holdSegment(2)      // 4.0 .. 6.0 s of the audio; the picture is all there
        let ready = await load(h)
        XCTAssertTrue(ready, "events: \(h.events)")
        let probe = try XCTUnwrap(probes.latest)
        h.engine.perform(.play(Epoch(1)))
        let stalled = await h.waitFor(.engineStalled(Epoch(1)), timeout: 15)
        XCTAssertTrue(stalled, "events: \(withoutTicks(h.events))")
        XCTAssertEqual(h.player.currentTime().seconds, hls.segmentStart(2), accuracy: 0.3)
        probe.poll()
        XCTAssertLessThan(probe.latest ?? Int.max, picture.frame(at: hls.segmentStart(2)) + 3, "the picture does not run on without the audio")
        hls.releaseSegment(2)
        let recovered = await h.wait { h.events.last == .engineRecovered(Epoch(1)) || (h.lastTick(of: Epoch(1)) ?? 0) > hls.segmentStart(2) + 0.6 }
        XCTAssertTrue(recovered, "events: \(h.events.suffix(8))")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 1)
    }

    func testAJumpOutOfAStallLandsElsewhereAndPlaysOnWithoutAnotherStall() async throws {
        let (h, hls, probes) = try await rig()
        hls.holdVideoSegment(2)      // 4.0 .. 6.0 s of the picture
        let ready = await load(h)
        XCTAssertTrue(ready)
        let probe = try XCTUnwrap(probes.latest)
        h.engine.perform(.play(Epoch(1)))
        let stalled = await h.waitFor(.engineStalled(Epoch(1)), timeout: 15)
        XCTAssertTrue(stalled, "events: \(withoutTicks(h.events))")

        // The viewer gives up waiting and jumps to a part that is there: the stall is over, and one jump out of it is all there is to say.
        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 20))
        let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(1)))
        XCTAssertTrue(landed, "events: \(withoutTicks(h.events))")
        let playsOn = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 20.6 }
        XCTAssertTrue(playsOn, "events: \(withoutTicks(h.events).suffix(8))")
        XCTAssertEqual(h.player.timeControlStatus, .playing)
        XCTAssertEqual(h.stalls(of: Epoch(1)), 1, "the one stall of the held part, no second one for the jump: \(withoutTicks(h.events))")
        XCTAssertTrue(h.events.contains(.engineRecovered(Epoch(1))), "and the player is said to be playing again")
        probe.poll()
        XCTAssertEqual(Double(probe.latest ?? -1), Double(picture.frame(at: h.player.currentTime().seconds)), accuracy: 3)
        hls.releaseVideoSegment(2)
    }

    // MARK: - A change of the audio

    func testChangingTheAudioUnderAPictureIsNoStallAndThePictureGoesOnWithoutAGap() async throws {
        let (h, hls, probes) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.8 }
        let probe = try XCTUnwrap(probes.latest)
        let item = try XCTUnwrap(h.player.currentItem)
        let loadedAudible = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let audible = try XCTUnwrap(loadedAudible)
        probe.forget()
        h.clearEvents()

        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 1)))
        // Watch the picture for two seconds (the probe asks for every frame by itself): it comes frame by frame, never back, with no hole of a quarter of a
        // second in it.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let steps = zip(probe.seen, probe.seen.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: audible)?.extendedLanguageTag, "de")
        XCTAssertGreaterThan(probe.seen.count, 40, "the picture kept coming: \(probe.seen.count) frames in two seconds")
        XCTAssertTrue(steps.allSatisfy { $0 > 0 }, "the picture does not go back: \(probe.seen.prefix(60))")
        XCTAssertLessThanOrEqual(steps.max() ?? 0, 6, "no hole in it: the longest gap between two frames was \(steps.max() ?? 0) frames")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "a choice of the viewer is no weak link: \(withoutTicks(h.events))")
        XCTAssertTrue(hls.server.requestedPaths.contains { $0.hasPrefix("/hi/audio-de/seg") }, "and it is the German that is loaded")
    }

    // MARK: - A swap of one stream for another

    func testAStreamWithAPictureIsReplacedByAnotherWhileItPlaysAndThePictureGoesOnFromWhereThePlayerWas() async throws {
        let (h, hls, probes) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 1.4 }
        h.clearEvents()

        h.engine.perform(.prepareSwap(Epoch(2), lo, startAt: 1.4, selection: none))
        let prepared = await h.waitFor(.swapPrepared(Epoch(2)))
        XCTAssertTrue(prepared, "events: \(withoutTicks(h.events))")
        XCTAssertTrue(hls.server.requestedPaths.contains(hls.videoPlaylistPath("lo")), "the picture of the other stream is loaded by the staging player: \(hls.server.requestedPaths)")
        XCTAssertEqual(path(of: h.player.currentItem), hls.masterPath("hi"), "the running stream is not touched")

        let playerIsAt = h.player.currentTime().seconds
        h.engine.perform(.commitSwap(Epoch(2), replacing: Epoch(1), at: playerIsAt - 0.4, selection: none))
        let finished = await h.waitFor(.swapFinished(Epoch(2)))
        XCTAssertTrue(finished, "events: \(withoutTicks(h.events))")
        let item = try XCTUnwrap(h.player.currentItem)
        XCTAssertEqual(path(of: item), hls.masterPath("lo"), "a copy of the prepared item is on the player")
        XCTAssertEqual(h.player.currentTime().seconds, playerIsAt, accuracy: 0.3)
        XCTAssertEqual(item.presentationSize, CGSize(width: 320, height: 180), "the copy has the picture")
        XCTAssertEqual(h.player.rate, 0, "a session starts paused")

        // (A copy has no output of the staging item's: the live item gets its own.)
        let probe = PictureProbe(item: item, watches: true)
        h.clearEvents()
        h.engine.perform(.play(Epoch(2)))
        let playsOn = await h.wait { (h.lastTick(of: Epoch(2)) ?? 0) > playerIsAt + 0.8 }
        XCTAssertTrue(playsOn, "events: \(h.events.suffix(6))")
        let shown = await frame(h, probe)
        XCTAssertEqual(Double(shown ?? -1), Double(picture.frame(at: h.player.currentTime().seconds)), accuracy: 4, "the picture of the other stream, at the clock")
        XCTAssertGreaterThan(probe.seen.first ?? 0, picture.frame(at: playerIsAt) - 3, "from where the player was and not from the start: \(probe.seen.prefix(5))")
        XCTAssertTrue(hls.server.requestedPaths.contains { $0.hasPrefix("/lo/video/seg") }, "and the live item loads the segments of the picture from the other stream")
        XCTAssertEqual(h.stalls(of: Epoch(2)), 0)
        XCTAssertFalse(h.events.contains { isFailure($0) })
        XCTAssertEqual(probes.all.count, 2, "the provider made two items")
    }

    // MARK: - A picture that is not there

    func testAReplacementWhosePictureIsNotThereIsAFailedSwapAndNeverATakeoverWithoutAPicture() async throws {
        // The audio of the other stream is there, its picture is not: AVPlayer does not fall back to the sound (measured: the item fails at once, 0.1 s,
        // `NSURLErrorDomain -1100`, with a picture output or without) - so the viewer is never left with a film that has lost its picture.
        let (h, hls, _) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        hls.server.fail(hls.videoPlaylistPath("lo"), status: 404)
        h.engine.perform(.prepareSwap(Epoch(2), lo, startAt: 0, selection: none))
        let failed = await h.wait(timeout: 15) { h.events.contains { if case .swapFailed(Epoch(2), _) = $0 { return true } else { return false } } }
        XCTAssertTrue(failed, "events: \(withoutTicks(h.events))")
        XCTAssertFalse(h.events.contains(.swapPrepared(Epoch(2))), "the audio alone did not make it a prepared item")
        XCTAssertFalse(h.events.contains { isFailure($0) }, "the running session did not fail")
        XCTAssertEqual(path(of: h.player.currentItem), hls.masterPath("hi"))
        XCTAssertGreaterThan(h.player.rate, 0)
        if case let .swapFailed(_, reason)? = h.events.last(where: { if case .swapFailed = $0 { return true } else { return false } }) {
            XCTAssertTrue(reason.contains("-1100"), "the reason keeps the code: \(reason)")
        }
    }

    func testAStreamWhosePictureIsNotThereFailsTheLoadAtOnce() async throws {
        let (h, hls, _) = try await rig()
        hls.server.fail(hls.videoPlaylistPath("hi"), status: 404)
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        let failed = await h.wait(timeout: 15) { h.events.contains { isFailure($0) } }
        XCTAssertTrue(failed, "events: \(h.events)")
        XCTAssertFalse(h.events.contains(.engineReady(Epoch(1))), "and it was never ready: the sound of it is not a film")
    }

    // MARK: - An engine that plays at once (the car's) on a stream with a picture

    func testAnEngineThatStartsAtOnceStartsAStreamWithAPictureWithoutAStall() async throws {
        let (h, _, probes) = try await rig(options: .init(startsPlayingAtOnce: true))
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        let ready = await h.waitFor(.engineReady(Epoch(1)))
        XCTAssertTrue(ready, "events: \(h.events)")
        let moved = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 1 }
        XCTAssertTrue(moved, "events: \(h.events.suffix(6))")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0)
        let probe = try XCTUnwrap(probes.latest)
        probe.poll()
        XCTAssertGreaterThan(probe.latest ?? 0, 20, "and the picture is there")
    }

    func testAPictureItemThatWasToldWhereToBeginWithThePlainSeekBeginsAtTheStartOfItsSegmentAndShowsThatFrame() async throws {
        // The car's way (the item is told before it loads), on segments of six seconds with a keyframe every two: where the item begins is the start of the
        // segment, not a keyframe inside it - the same as the cheap jump into a part that is not loaded.
        let (h, hls, probes) = try await rig(segmentSeconds: 6, options: .init(startsPlayingAtOnce: true))
        h.make = { [unowned hls] _, _ in
            let item = AVPlayerItem(url: hls.masterURL("hi"))
            item.seek(to: CMTime(seconds: 15.6, preferredTimescale: 600), completionHandler: nil)
            probes.all.append(PictureProbe(item: item, watches: true))
            return item
        }
        h.engine.perform(.load(Epoch(1), film, startAt: 15.6, selection: none, quality: nil))
        let ready = await h.waitFor(.engineReady(Epoch(1)))
        XCTAssertTrue(ready, "events: \(h.events)")
        let moved = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 12.5 }
        XCTAssertTrue(moved, "events: \(h.ticks(of: Epoch(1)).prefix(4))")
        let first = h.ticks(of: Epoch(1)).first ?? 0
        XCTAssertEqual(first, hls.videoSegmentStart(2) + 0.3, accuracy: 0.5, "from the start of its segment (12.0), not from 14.0 or 16.0 inside it, nor from the 15.6: \(h.ticks(of: Epoch(1)).prefix(4))")
        let probe = try XCTUnwrap(probes.latest)
        XCTAssertLessThan(probe.seen.first ?? Int.max, picture.frame(at: 12.0) + 6, "the first picture is the segment's first frame: \(probe.seen.prefix(5))")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0)
    }
}
