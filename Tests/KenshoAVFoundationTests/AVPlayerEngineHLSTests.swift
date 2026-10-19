import XCTest
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// `AVPlayerEngine` against a real `AVPlayer` playing an HLS stream from the loopback (`HLSFixture`): a master playlist, alternate audio and subtitle
/// renditions, segments that come over HTTP one by one - and one that a test can keep back. What the engine does at a stall, at a jump into a part that
/// is not loaded, at a track choice on a real media selection group and at a swap of one stream for another is what files on disk could not show.
///
/// The stream is audio only (`HLSFixture`); segment N is `hls.segmentStart(N)` seconds in, and about two seconds long.
@MainActor
final class AVPlayerEngineHLSTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .sdr)
    private let none = TrackSelection()
    private let lo = QualityChoice(id: "lo", range: .sdr)
    /// The segment a stall test keeps back (4.0 .. 6.0 s): four seconds of data are enough for AVPlayer to begin and short enough to wait for.
    private let heldSegment = 2

    private func rig(
        seconds: TimeInterval = 30, applier: AVPlayerEngine.SelectionApplier? = nil, options: AVPlayerEngine.Options = AVPlayerEngine.Options()
    ) async throws -> (h: EngineHarness, hls: HLSFixture) {
        let hls = try await HLSFixture.start(seconds: seconds)
        let h = try EngineHarness(applier: applier, options: options)
        h.files["film"] = hls.masterURL("hi")
        h.files["film-lo"] = hls.masterURL("lo")
        h.retained.append(hls)
        return (h, hls)
    }

    /// Loads (paused at `startAt`, with `selection` applied) and waits until the engine says it is ready.
    private func load(_ h: EngineHarness, startAt: TimeInterval = 0, selection: TrackSelection = TrackSelection(), epoch: Epoch = Epoch(1)) async -> Bool {
        h.engine.perform(.load(epoch, film, startAt: startAt, selection: selection, quality: nil))
        return await h.waitFor(.engineReady(epoch))
    }

    private func groups(of item: AVPlayerItem) async throws -> (audible: AVMediaSelectionGroup, legible: AVMediaSelectionGroup) {
        let audible = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let legible = try await item.asset.loadMediaSelectionGroup(for: .legible)
        return (try XCTUnwrap(audible), try XCTUnwrap(legible))
    }

    /// The language of the option the item has selected in the group.
    private func tag(_ item: AVPlayerItem, _ group: AVMediaSelectionGroup) -> String? {
        item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag
    }

    private func path(of item: AVPlayerItem?) -> String? { (item?.asset as? AVURLAsset)?.url.path }

    /// A flag a KVO callback may set from wherever AVFoundation calls it.
    private final class Flag: @unchecked Sendable { var isSet = false }

    private func isFailure(_ event: PlaybackEvent) -> Bool { if case .engineFailed = event { return true } else { return false } }

    // MARK: - A stall is the stream running dry, not the engine's own moves

    func testAStreamThatRunsDryWhilePlayingIsAStallAndItsDataComingIsTheRecovery() async throws {
        let (h, hls) = try await rig()
        hls.holdSegment(heldSegment)      // what the player has ends where this begins
        let ready = await load(h)
        XCTAssertTrue(ready, "events: \(h.events)")
        h.engine.perform(.play(Epoch(1)))

        let stalled = await h.waitFor(.engineStalled(Epoch(1)), timeout: 15)
        XCTAssertTrue(stalled, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        let dryAt = h.player.currentTime().seconds
        XCTAssertEqual(dryAt, hls.segmentStart(heldSegment), accuracy: 0.3, "it ran dry where the data ends, after it had played")
        XCTAssertEqual(h.player.timeControlStatus, .waitingToPlayAtSpecifiedRate)

        // Said once, and not undone while the data is not there.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let stallIndex = try XCTUnwrap(h.events.lastIndex(of: .engineStalled(Epoch(1))))
        XCTAssertEqual(h.stalls(of: Epoch(1)), 1, "events: \(h.events.suffix(8))")
        XCTAssertFalse(h.events[stallIndex...].contains(.engineRecovered(Epoch(1))))
        XCTAssertEqual(h.player.currentTime().seconds, dryAt, accuracy: 0.05, "and the position stood still")

        hls.releaseSegment(heldSegment)
        let recovered = await h.wait { h.events[stallIndex...].contains(.engineRecovered(Epoch(1))) }
        XCTAssertTrue(recovered, "events: \(h.events.suffix(8))")
        let playsOn = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > hls.segmentStart(heldSegment) + 0.6 }
        XCTAssertTrue(playsOn, "and it plays on through the part that was kept back")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 1)
    }

    func testAStartThatNeverGetsGoingIsAStallOnceTheGraceIsOver() async throws {
        let (h, hls) = try await rig()
        hls.holdSegment(3)      // 6.0 s on; the start is at 5.0, so there is a second of data and AVPlayer does not begin on it
        let ready = await load(h, startAt: 5)
        XCTAssertTrue(ready, "events: \(h.events)")
        let playedAt = Date()
        h.engine.perform(.play(Epoch(1)))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(h.player.timeControlStatus, .waitingToPlayAtSpecifiedRate, "the player is waiting to start (else this test shows nothing)")
        XCTAssertEqual(h.player.currentTime().seconds, 5, accuracy: 0.05)
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "a start is allowed its time")
        let stalled = await h.waitFor(.engineStalled(Epoch(1)), timeout: 5)
        XCTAssertTrue(stalled, "a start that does not come is as much a thing to act on as a stream that broke off: \(h.events)")
        XCTAssertGreaterThan(Date().timeIntervalSince(playedAt), StallWatch.resumeGrace - 0.2)
        hls.releaseSegment(3)
        let playsOn = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 6.5 }
        XCTAssertTrue(playsOn, "and when the data comes it plays")
    }

    func testStartingToPlayAnHLSStreamIsNoStall() async throws {
        let (h, _) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.clearEvents()
        h.engine.perform(.play(Epoch(1)))
        let playing = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 1.5 }
        XCTAssertTrue(playing, "events: \(h.events.suffix(6))")
        // (AVPlayer shows `waitingToPlayAtSpecifiedRate` for a few milliseconds after every `play()`, as it does for a file.)
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
    }

    func testAStreamWhoseFirstSegmentDoesNotComeIsNeitherReadyNorFailed() async throws {
        let (h, hls) = try await rig()
        hls.holdSegment(0)
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        // An HLS item is `readyToPlay` only when it has its first segment; until then the session loads, and nothing is said. (A deadline for that is the
        // owner's business, as for a provider that does not answer: the engine has none.)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(h.events.isEmpty, "events: \(h.events)")
        hls.releaseSegment(0)
        let ready = await h.waitFor(.engineReady(Epoch(1)))
        XCTAssertTrue(ready, "events: \(h.events)")
        XCTAssertFalse(h.events.contains { isFailure($0) })
    }

    func testAJumpIntoAPartThatIsNotThereYetIsNeitherAStallNorLandedBeforeItsDataComes() async throws {
        let (h, hls) = try await rig()
        hls.holdSegment(6)      // 12.0 .. 14.0 s
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.8 }
        h.clearEvents()

        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 12.5))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(h.player.timeControlStatus, .waitingToPlayAtSpecifiedRate, "the player waits for the segment (else this test shows nothing)")
        XCTAssertFalse(h.events.contains(.seekFinished(Epoch(1), SeekToken(1))), "the jump has not landed: where it goes is not there")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "the wait of a jump is the jump: \(h.events)")

        hls.releaseSegment(6)
        let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(1)))
        XCTAssertTrue(landed, "events: \(h.events)")
        XCTAssertEqual(h.player.currentTime().seconds, 12.5, accuracy: 0.15)
        let playsOn = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 13.2 }
        XCTAssertTrue(playsOn, "and plays on from there")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "nor was the start from the new place one: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
    }

    func testRunningDryAfterAJumpHasLandedIsAStallAgain() async throws {
        let (h, hls) = try await rig()
        hls.holdSegment(8)      // 16.0 .. 18.0 s; the jump goes to four and a half seconds before it, enough for AVPlayer to begin (with three it did not)
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.5 }
        h.clearEvents()

        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 11.5))
        let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(1)))
        XCTAssertTrue(landed, "events: \(h.events)")
        let stalled = await h.waitFor(.engineStalled(Epoch(1)), timeout: 10)
        XCTAssertTrue(stalled, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        let order = h.events.filter { $0 == .seekFinished(Epoch(1), SeekToken(1)) || $0 == .engineStalled(Epoch(1)) }
        XCTAssertEqual(order, [.seekFinished(Epoch(1), SeekToken(1)), .engineStalled(Epoch(1))], "the jump landed first and then the player ran dry")
        XCTAssertEqual(h.player.currentTime().seconds, hls.segmentStart(8), accuracy: 0.3, "after it had played the data it had")
        hls.releaseSegment(8)
        let recovered = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > hls.segmentStart(8) + 0.5 }
        XCTAssertTrue(recovered)
    }

    func testChangingTheAudioWhileItPlaysIsNoStall() async throws {
        let (h, hls) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.8 }
        let item = try XCTUnwrap(h.player.currentItem)
        let (audible, _) = try await groups(of: item)
        // The premise, seen on the player itself: another audio rendition is not an edit of the one that plays - AVPlayer drops what it had and waits for the
        // other (measured: `playing` -> `waitingToPlayAtSpecifiedRate` for some tens of milliseconds, the reason the very one of a real stall).
        let waited = Flag()
        let observation = h.player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { waited.isSet = true }
        }
        h.clearEvents()

        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 1)))
        let switched = await h.wait { self.tag(item, audible) == "de" }
        XCTAssertTrue(switched)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(waited.isSet, "the player waited for the other rendition (else this test shows nothing)")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "a choice of the viewer is no weak link: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        XCTAssertTrue(hls.server.requestedPaths.contains { $0.hasPrefix("/hi/audio-de/seg") }, "and it is the German that is loaded now")

        // The way back, to what AVFoundation chooses itself, is a change as well.
        waited.isSet = false
        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: nil)))
        let back = await h.wait { self.tag(item, audible) == "en" }
        XCTAssertTrue(back)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(waited.isSet)
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0)
        observation.invalidate()
    }

    func testAnAppliersSlownessDoesNotTurnItsChangeIntoAStall() async throws {
        // An applier of the app's own may take its time before it changes the item; the wait is still the change's.
        let (h, _) = try await rig(applier: { item, selection in
            if selection.audio == 1 { try? await Task.sleep(nanoseconds: 1_300_000_000) }
            await AVPlayerEngine.defaultApplier(item, selection)
        })
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.8 }
        let item = try XCTUnwrap(h.player.currentItem)
        let (audible, _) = try await groups(of: item)
        let waited = Flag()
        let observation = h.player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { waited.isSet = true }
        }
        h.clearEvents()

        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 1)))
        let switched = await h.wait(timeout: 5) { self.tag(item, audible) == "de" }
        XCTAssertTrue(switched)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(waited.isSet, "the player waited for the other rendition (else this test shows nothing)")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        observation.invalidate()
    }

    func testAnAudioChoiceWhoseDataDoesNotComeIsAStallAfterTheGraceAfterAll() async throws {
        let (h, hls) = try await rig()
        // The German of the second the player will be at is not to be had.
        hls.server.hold(hls.segmentPath(audio: "de", hls.segmentIndex(at: 9.5)))
        let ready = await load(h, startAt: 9)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 9.3 }
        h.clearEvents()

        let choseAt = Date()
        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 1)))
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "for the first seconds the wait is the choice")
        XCTAssertEqual(h.player.timeControlStatus, .waitingToPlayAtSpecifiedRate, "and it goes on")
        let stalled = await h.waitFor(.engineStalled(Epoch(1)), timeout: 6)
        XCTAssertTrue(stalled, "a wait that lasts is one: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        XCTAssertGreaterThan(Date().timeIntervalSince(choseAt), StallWatch.resumeGrace - 0.5, "but not before the grace of a start is over")
        hls.server.release(hls.segmentPath(audio: "de", hls.segmentIndex(at: 9.5)))
        let recovered = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 10.5 }
        XCTAssertTrue(recovered, "and the German plays when it comes")
    }

    // MARK: - The default applier on the groups of a stream

    func testTheDefaultApplierChoosesAudioAndSubtitleOfARealStreamAtTheirNumbers() async throws {
        let hls = try await HLSFixture.start(seconds: 10)
        let player = AVPlayer()
        player.isMuted = true
        let item = AVPlayerItem(url: hls.masterURL())
        player.replaceCurrentItem(with: item)
        let h = try EngineHarness()
        let ready = await h.wait { item.status == .readyToPlay }
        XCTAssertTrue(ready, "\(String(describing: item.error))")
        let (audible, legible) = try await groups(of: item)
        XCTAssertNil(tag(item, legible), "no subtitle on its own")

        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 1, subtitle: 1))
        XCTAssertEqual(tag(item, audible), "de")
        XCTAssertEqual(tag(item, legible), "de")
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 0, subtitle: 0))
        XCTAssertEqual(tag(item, audible), "en")
        XCTAssertEqual(tag(item, legible), "en")
        // "off" is a choice the group allows: nothing is selected afterwards.
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 0, subtitle: nil))
        XCTAssertNil(tag(item, legible), "subtitles off")
        XCTAssertEqual(tag(item, audible), "en")

        // A number the stream has no option for changes nothing: for the subtitles it used to turn them off.
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 1, subtitle: 1))
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 7, subtitle: 7))
        XCTAssertEqual(tag(item, audible), "de", "what the viewer had stays")
        XCTAssertEqual(tag(item, legible), "de", "and the subtitles are not turned off by a number that is no option")
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: -1, subtitle: -1))
        XCTAssertEqual(tag(item, audible), "de")
        XCTAssertEqual(tag(item, legible), "de")

        // "No choice" for the audio goes back to what AVFoundation picks on its own (the one the master plays by default).
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: nil, subtitle: 1))
        XCTAssertEqual(tag(item, audible), "en")
        XCTAssertEqual(tag(item, legible), "de")
    }

    func testTheEngineAppliesTheTracksOfALoadToTheRealStreamAndTheNumbersAreWhatIsLoaded() async throws {
        let (h, hls) = try await rig()
        let ready = await load(h, selection: TrackSelection(audio: 1, subtitle: 0))
        XCTAssertTrue(ready, "events: \(h.events)")
        let item = try XCTUnwrap(h.player.currentItem)
        let (audible, legible) = try await groups(of: item)
        XCTAssertEqual(tag(item, audible), "de", "the track of the load is in force when the session is ready")
        XCTAssertEqual(tag(item, legible), "en")

        // Not a mark on an item but what the player loads and plays.
        h.engine.perform(.play(Epoch(1)))
        let loaded = await h.wait { hls.server.requestedPaths.contains(hls.subtitleSegmentPath(code: "en")) && hls.server.requestedPaths.contains(hls.segmentPath(audio: "de", 2)) }
        XCTAssertTrue(loaded, "requests: \(hls.server.requestedPaths)")
        XCTAssertFalse(hls.server.requestedPaths.contains(hls.subtitleSegmentPath(code: "de")), "the subtitle that was not chosen is not loaded")

        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 0, subtitle: 1)))
        let changed = await h.wait { self.tag(item, audible) == "en" && self.tag(item, legible) == "de" }
        XCTAssertTrue(changed)
        let German = await h.wait { hls.server.requestedPaths.contains(hls.subtitleSegmentPath(code: "de")) }
        XCTAssertTrue(German, "requests: \(hls.server.requestedPaths)")
    }

    // MARK: - Jumping in a stream of segments

    func testAStartPositionInAnHLSStreamIsReachedOnTheSecondAndNotAtTheSegmentBefore() async throws {
        let (h, hls) = try await rig()
        let ready = await load(h, startAt: 13)
        XCTAssertTrue(ready, "events: \(h.events)")
        XCTAssertEqual(h.player.currentTime().seconds, 13, accuracy: 0.05, "not the 12.0 at which its segment begins")
        XCTAssertEqual(h.player.rate, 0)
        h.engine.perform(.play(Epoch(1)))
        let playsOn = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 13.5 }
        XCTAssertTrue(playsOn)
        XCTAssertGreaterThan(h.ticks(of: Epoch(1)).first ?? 0, 12.9, "and never from the start: \(h.ticks(of: Epoch(1)).prefix(3))")
        _ = hls
    }

    func testAJumpInAnHLSStreamLandsOnTheSecondAndIsReportedWithItsToken() async throws {
        let (h, _) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.5 }
        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 20.4))
        let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(1)))
        XCTAssertTrue(landed, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        XCTAssertEqual(h.player.currentTime().seconds, 20.4, accuracy: 0.3, "zero tolerance, and the player has played on a little since")
        let playsOn = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 21 }
        XCTAssertTrue(playsOn)
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0)
    }

    func testAJumpWhilePausedInAnHLSStreamLandsAndStaysPut() async throws {
        let (h, _) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 13))
        let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(1)))
        XCTAssertTrue(landed)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(h.player.currentTime().seconds, 13, accuracy: 0.02, "exactly there - not at the 12.0 where its segment begins - and not moving")
        XCTAssertEqual(h.player.rate, 0)
    }

    func testAJumpBeyondTheEndOfAnHLSStreamLandsAtItsEnd() async throws {
        let (h, _) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 5_000))
        let answered = await h.wait { h.events.contains(.seekFinished(Epoch(1), SeekToken(1))) || h.events.contains { self.isFailure($0) } }
        XCTAssertTrue(answered, "events: \(h.events)")
        XCTAssertTrue(h.events.contains(.seekFinished(Epoch(1), SeekToken(1))), "a target past the end is no failure of the session: \(h.events)")
        let duration = try XCTUnwrap(h.player.currentItem).duration.seconds
        XCTAssertEqual(h.player.currentTime().seconds, duration, accuracy: 0.15)
    }

    func testAStartPositionBeyondTheEndOfAnHLSStreamIsNoFailureEither() async throws {
        let (h, _) = try await rig()
        h.engine.perform(.load(Epoch(1), film, startAt: 5_000, selection: none, quality: nil))
        let answered = await h.wait { h.events.contains(.engineReady(Epoch(1))) || h.events.contains { self.isFailure($0) } }
        XCTAssertTrue(answered, "events: \(h.events)")
        XCTAssertTrue(h.events.contains(.engineReady(Epoch(1))), "events: \(h.events)")
    }

    func testACheapJumpInASegmentedStreamLandsAtTheSegmentThatHoldsItAndTheExactOneOnTheSecond() async throws {
        for (options, label) in [(AVPlayerEngine.Options(jumps: .exact), "exact"), (AVPlayerEngine.Options(jumps: .cheapest), "cheapest")] {
            let (h, hls) = try await rig(options: options)
            let ready = await load(h)
            XCTAssertTrue(ready, label)
            // (Paused and at the start: the player has only the first segments, so the one that holds 29.9 s is one it has to fetch.)
            h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 29.9))
            let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(1)))
            XCTAssertTrue(landed, "\(label): \(h.events)")
            let landing = h.player.currentTime().seconds
            let segmentStart = hls.segmentStart(hls.segmentIndex(at: 29.9))
            switch options.jumps {
            case .exact:
                XCTAssertEqual(landing, 29.9, accuracy: 0.02, "exact: the target, not the \(segmentStart) at which its segment begins")
            case .cheapest:
                // Where AVPlayer lands most cheaply: at the target if that part is loaded, at the beginning of its segment if it is not. Measured with
                // the default `seek(to:)` the car's engine used - the same: 28.003 for 29.9 on a player that had not loaded it.
                XCTAssertLessThanOrEqual(landing, 29.9 + 0.02, "cheapest, landed at \(landing)")
                XCTAssertGreaterThanOrEqual(landing, segmentStart - 0.02, "cheapest, landed at \(landing)")
            }
        }
    }

    // MARK: - Making a replacement of one stream by another

    func testAnHLSStreamIsReplacedByAnotherWhileItPlaysAndTheOtherTakesOverWhereThePlayerIs() async throws {
        let (h, hls) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 1.4 }
        h.clearEvents()

        h.engine.perform(.prepareSwap(Epoch(2), lo, startAt: 1.4, selection: none))
        let prepared = await h.waitFor(.swapPrepared(Epoch(2)))
        XCTAssertTrue(prepared, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        XCTAssertTrue(hls.server.requestedPaths.contains(hls.masterPath("lo")), "the other stream is loaded, over HTTP, by the staging player")
        XCTAssertEqual(path(of: h.player.currentItem), hls.masterPath("hi"), "the running stream is not touched")
        XCTAssertGreaterThan(h.player.rate, 0)
        let reporting = await h.wait(timeout: 3) { !h.ticks(of: Epoch(1)).isEmpty }
        XCTAssertTrue(reporting, "and it goes on reporting under its own epoch")

        let playerIsAt = h.player.currentTime().seconds
        h.engine.perform(.commitSwap(Epoch(2), replacing: Epoch(1), at: playerIsAt - 0.4, selection: none))
        let finished = await h.waitFor(.swapFinished(Epoch(2)))
        XCTAssertTrue(finished, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        XCTAssertEqual(path(of: h.player.currentItem), hls.masterPath("lo"), "a copy of the prepared item is on the player")
        XCTAssertEqual(h.player.currentTime().seconds, playerIsAt, accuracy: 0.3, "where the player was, not where the last tick said")
        XCTAssertEqual(h.player.rate, 0, "a session starts paused")

        h.clearEvents()
        h.engine.perform(.play(Epoch(2)))
        let playsOn = await h.wait { (h.lastTick(of: Epoch(2)) ?? 0) > playerIsAt + 0.6 }
        XCTAssertTrue(playsOn, "events: \(h.events.suffix(6))")
        XCTAssertTrue(h.ticks(of: Epoch(1)).isEmpty, "the old session says nothing any more")
        XCTAssertEqual(h.stalls(of: Epoch(2)), 0)
        XCTAssertFalse(h.events.contains { isFailure($0) })
    }

    func testTheReplacementCarriesTheViewersTracksThoughTheCopyDoesNotKeepThePreparedItemsChoice() async throws {
        let (h, hls) = try await rig()
        let ready = await load(h, selection: TrackSelection(audio: 1, subtitle: 1))
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        h.engine.perform(.prepareSwap(Epoch(2), lo, startAt: 0, selection: TrackSelection(audio: 1, subtitle: 1)))
        let prepared = await h.waitFor(.swapPrepared(Epoch(2)))
        XCTAssertTrue(prepared)
        h.engine.perform(.commitSwap(Epoch(2), replacing: Epoch(1), at: 1, selection: TrackSelection(audio: 1, subtitle: 1)))
        let finished = await h.waitFor(.swapFinished(Epoch(2)))
        XCTAssertTrue(finished)
        let item = try XCTUnwrap(h.player.currentItem)
        XCTAssertEqual(path(of: item), hls.masterPath("lo"))
        let (audible, legible) = try await groups(of: item)
        XCTAssertEqual(tag(item, audible), "de", "the choice is made again on the item that took over")
        XCTAssertEqual(tag(item, legible), "de")
    }

    func testAReplacementWhoseStreamIsNotThereIsAFailedSwapAndTheRunningStreamPlaysOn() async throws {
        let (h, hls) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        hls.server.fail(hls.masterPath("lo"), status: 404)
        h.engine.perform(.prepareSwap(Epoch(2), lo, startAt: 0, selection: none))
        let failed = await h.wait(timeout: 30) { h.events.contains { if case .swapFailed(Epoch(2), _) = $0 { return true } else { return false } } }
        XCTAssertTrue(failed, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        XCTAssertFalse(h.events.contains { isFailure($0) }, "the running session did not fail")
        XCTAssertEqual(path(of: h.player.currentItem), hls.masterPath("hi"))
        XCTAssertGreaterThan(h.player.rate, 0)
    }

    // MARK: - The end of a stream

    func testTheEndOfAStreamReachesTheReducerAsThePauseOfTheViewerBecauseTheModelHasNoEnd() async throws {
        // This pins what is, not what should be: `AVPlayer` stops at the end of the item by itself (`rate` 0, nothing the engine asked for), and the engine
        // tells every such change as the viewer's pause. When the model gets an end of its own (Docs/Zusammenfuehrung.md), this is the test that changes.
        let (h, _) = try await rig(seconds: 4)
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.clearEvents()
        h.engine.perform(.play(Epoch(1)))
        let paused = await h.waitFor(.pause, timeout: 12)
        XCTAssertTrue(paused, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        XCTAssertEqual(h.events.filter { $0 == .pause }.count, 1)
        XCTAssertEqual(h.player.currentTime().seconds, try XCTUnwrap(h.player.currentItem).duration.seconds, accuracy: 0.3, "at the end")
        XCTAssertFalse(h.events.contains { isFailure($0) })
    }

    /// AVPlayer does not give up on a segment that answers 404 in the middle of playing for a long time: it waits (`toMinimizeStalls`), asks again, and
    /// posts `AVPlayerItemFailedToPlayToEndTime` (`NSURLErrorDomain -1100`) after some twenty seconds - while `item.status` stays `readyToPlay`.
    /// Measured on 2026-10-19: 22 s after the wait began. The notification is the way the engine hears of it.
    func testAStreamThatDiesWhilePlayingIsStalledForAWhileAndThenFailsWithTheNotification() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KENSHO_SLOW_TESTS"] != nil, "about 25 s: set KENSHO_SLOW_TESTS=1 to run it")
        let (h, hls) = try await rig()
        for rendition in HLSFixture.audioRenditions { hls.server.fail(hls.segmentPath(audio: rendition.code, 4), status: 404) }
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        let stalled = await h.waitFor(.engineStalled(Epoch(1)), timeout: 15)
        XCTAssertTrue(stalled)
        let failed = await h.wait(timeout: 60) { h.events.contains { self.isFailure($0) } }
        XCTAssertTrue(failed, "events: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
        if case let .engineFailed(epoch, reason)? = h.events.last(where: { isFailure($0) }) {
            XCTAssertEqual(epoch, Epoch(1))
            XCTAssertTrue(reason.contains("-1100"), "the reason keeps the code: \(reason)")
        }
        XCTAssertEqual(h.player.currentItem?.status, .readyToPlay, "the status never said so")
    }
}
