import XCTest
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// `AVPlayerEngine` against a real `AVPlayer` playing short files written at
/// test time (muted, and silent as well). Nothing here is a mock of AVFoundation:
/// what the player does at the start of a play, at a seek and at a swap is
/// exactly what these tests are for.
@MainActor
private final class EngineHarness {
    enum Failure: Error { case noItem(String) }

    let directory: URL
    let player = AVPlayer()
    private(set) var engine: AVPlayerEngine!
    private(set) var events: [PlaybackEvent] = []
    private(set) var provided: [(MediaSource, QualityChoice?)] = []
    /// What the provider was asked, whole.
    private(set) var requests: [AVPlayerEngine.ItemRequest] = []
    /// Files by name; the default provider maps `source.id` (or `source.id-quality.id`) to one.
    var files: [String: URL] = [:]
    /// What the provider does, per call. Replaced by tests that need a slow or failing one.
    var make: ((MediaSource, QualityChoice?) async throws -> AVPlayerItem)?

    init(applier: AVPlayerEngine.SelectionApplier? = nil, options: AVPlayerEngine.Options = AVPlayerEngine.Options()) throws {
        directory = try TestMedia.makeDirectory()
        player.isMuted = true
        engine = AVPlayerEngine(
            player: player,
            provider: { [weak self] request in
                // (A session the test has left may still ask: nothing is there to answer.)
                guard let self else { throw Failure.noItem("the test is over") }
                let source = request.source, quality = request.quality
                self.provided.append((source, quality))
                self.requests.append(request)
                if let make = self.make { return try await make(source, quality) }
                let key = quality.map { "\(source.id)-\($0.id)" } ?? source.id
                guard let url = self.files[key] ?? self.files[source.id] else { throw Failure.noItem(key) }
                return AVPlayerItem(url: url)
            },
            applier: applier,
            options: options
        )
        engine.onEvent = { [weak self] in self?.events.append($0) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func addFile(_ name: String, seconds: Double) throws {
        files[name] = try TestMedia.silentAudio(seconds: seconds, in: directory, name: name)
    }

    /// Polls until `condition` holds; the run loop keeps turning while it waits.
    @discardableResult
    func wait(timeout: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @discardableResult
    func waitFor(_ event: PlaybackEvent, timeout: TimeInterval = 10) async -> Bool {
        await wait(timeout: timeout) { self.events.contains(event) }
    }

    func clearEvents() { events.removeAll() }

    func stalls(of epoch: Epoch) -> Int { events.filter { $0 == .engineStalled(epoch) }.count }

    func ticks(of epoch: Epoch) -> [TimeInterval] {
        events.compactMap { if case let .engineTick(e, position) = $0, e == epoch { return position } else { return nil } }
    }

    /// The last position the engine reported for the epoch.
    func lastTick(of epoch: Epoch) -> TimeInterval? { ticks(of: epoch).last }
}

@MainActor
final class AVPlayerEngineTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .sdr)
    private let none = TrackSelection()

    private func harness(applier: AVPlayerEngine.SelectionApplier? = nil, options: AVPlayerEngine.Options = AVPlayerEngine.Options()) throws -> EngineHarness {
        let h = try EngineHarness(applier: applier, options: options)
        try h.addFile("film", seconds: 30)
        try h.addFile("film-lo", seconds: 20)
        return h
    }

    // MARK: - Starting

    func testALoadReportsReadyAndWaitsPausedAtTheStartPosition() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 4, selection: none, quality: nil))
        let ready = await h.waitFor(.engineReady(Epoch(1)))
        XCTAssertTrue(ready, "events: \(h.events)")
        XCTAssertEqual(h.player.rate, 0, "a session starts paused: the reducer's play is what sets it going")
        XCTAssertEqual(h.player.currentTime().seconds, 4, accuracy: 0.2)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(h.player.currentTime().seconds, 4, accuracy: 0.2, "it stayed where it was told to wait")
        XCTAssertEqual(h.provided.count, 1)
    }

    // MARK: - An engine that plays at once (the car's)

    func testAnEngineThatStartsAtOnceIsPlayingWhenItReportsReadyAndWasNeverToldToPlay() async throws {
        let h = try harness(options: .init(startsPlayingAtOnce: true))
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        let ready = await h.waitFor(.engineReady(Epoch(1)))
        XCTAssertTrue(ready, "events: \(h.events)")
        XCTAssertGreaterThan(h.player.rate, 0, "no `play` was performed: the item was set going as it went on the player")
        let moved = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.8 }
        XCTAssertTrue(moved, "and it runs: \(h.events)")
    }

    func testAnEngineThatStartsAtOnceDoesNotPlayAnItemThatArrivesAfterAPause() async throws {
        let h = try harness(options: .init(startsPlayingAtOnce: true))
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        h.engine.perform(.pause(Epoch(1)))       // before the provider has answered
        let ready = await h.waitFor(.engineReady(Epoch(1)))
        XCTAssertTrue(ready, "events: \(h.events)")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(h.player.rate, 0, "held: the pause came before the item did")
        XCTAssertLessThan(h.player.currentTime().seconds, 0.3)
        h.engine.perform(.play(Epoch(1)))
        let moved = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.6 }
        XCTAssertTrue(moved, "and the play after it sets it going: \(h.events)")
    }

    func testAnEngineThatStartsAtOnceLeavesTheStartPositionToTheItem() async throws {
        // The provider's item was not told to begin anywhere. The default engine would jump to the 10 s it was asked for and wait for the landing; this one
        // plays from where the item begins.
        let h = try harness(options: .init(startsPlayingAtOnce: true))
        h.engine.perform(.load(Epoch(1), film, startAt: 10, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertLessThan(h.player.currentTime().seconds, 4, "it did not jump to the start position: \(h.player.currentTime().seconds)")
        XCTAssertEqual(h.requests.first?.startAt, 10, "the provider was told where the film is wanted: it is the one who positions the item")
    }

    func testAnItemThatWasToldWhereToBeginBeginsThereWhenTheEnginePlaysAtOnce() async throws {
        let h = try harness(options: .init(startsPlayingAtOnce: true))
        h.make = { [unowned h] _, _ in
            let item = AVPlayerItem(url: h.files["film"]!)
            item.seek(to: CMTime(seconds: 12, preferredTimescale: 600), completionHandler: nil)
            return item
        }
        h.engine.perform(.load(Epoch(1), film, startAt: 12, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        let moved = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 12.4 }
        XCTAssertTrue(moved, "it runs from the 12 s the item was told: \(h.ticks(of: Epoch(1)).prefix(4))")
        XCTAssertGreaterThan(h.ticks(of: Epoch(1)).first ?? 0, 11.5, "and never from the start: \(h.ticks(of: Epoch(1)).prefix(4))")
    }

    func testTheDefaultEngineStillWaitsForThePlayInstruction() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        XCTAssertEqual(h.player.rate, 0)
    }

    func testACheapJumpLands() async throws {
        let h = try harness(options: .init(jumps: .cheapest))
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        h.clearEvents()
        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 20))
        let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(1)))
        XCTAssertTrue(landed, "events: \(h.events)")
        XCTAssertEqual(h.player.currentTime().seconds, 20, accuracy: 1.5, "(a file of audio has no keyframes to snap to: this checks that the jump is made and answered; what a segmented stream does with it is for one to show)")
    }

    func testPlayRunsFromThereAndEveryTickCarriesTheEpoch() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 4, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.clearEvents()
        h.engine.perform(.play(Epoch(1)))
        let moved = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 5 }
        XCTAssertTrue(moved, "events: \(h.events)")
        XCTAssertFalse(h.events.contains { if case let .engineTick(e, _) = $0 { return e != Epoch(1) } else { return false } })
    }

    func testANewLoadDoesNotStartOnItsOwnJustBecauseTheOldItemWasPlaying() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        await h.wait { h.player.rate > 0 }
        h.engine.perform(.load(Epoch(2), film, startAt: 10, selection: none, quality: nil))
        let ready = await h.waitFor(.engineReady(Epoch(2)))
        XCTAssertTrue(ready)
        // AVPlayer keeps its rate across `replaceCurrentItem`: without a pause the new item would play 10 s of the wrong place... from the start.
        XCTAssertEqual(h.player.rate, 0)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(h.player.currentTime().seconds, 10, accuracy: 0.2)
    }

    func testStartingToPlayIsNotAStall() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.clearEvents()
        h.engine.perform(.play(Epoch(1)))
        let playing = await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 1 }
        XCTAssertTrue(playing, "events: \(h.events)")
        // Waiting for the first data after play() is how every start looks to AVPlayer. Only running dry after it has played is a stall.
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "events: \(h.events)")
    }

    // MARK: - What the system does to the player

    func testAPauseThatTheEngineDidNotCauseIsReportedAsThePauseItIs() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        await h.wait { h.player.rate > 0 }
        h.clearEvents()
        // A call, Siri, the route going away or the app going to the background stops an AVPlayer by itself (AVPlayer.h: rate 0 on an interruption).
        // Nothing the reducer asked for: without a report it goes on thinking the film plays, and its next `play` is a no-op.
        h.player.pause()
        let told = await h.waitFor(.pause)
        XCTAssertTrue(told, "events: \(h.events)")
    }

    func testAPlayThatTheEngineDidNotCauseIsReportedAsThePlayItIs() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.clearEvents()
        h.player.play()     // the picture is started by something else (system UI, a view that has its own transport)
        let told = await h.waitFor(.play)
        XCTAssertTrue(told, "events: \(h.events)")
    }

    func testWhatTheEngineDoesItselfIsNotReportedBackAsTheViewersIntent() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.clearEvents()
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.4 }
        h.engine.perform(.pause(Epoch(1)))
        try await Task.sleep(nanoseconds: 700_000_000)
        h.engine.perform(.play(Epoch(1)))
        await h.wait { h.player.rate > 0 }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(h.events.contains(.pause) || h.events.contains(.play), "an echo would turn every instruction into an intent: \(h.events)")
    }

    // MARK: - What the provider is told

    func testTheProviderIsToldWhereTheItemIsWantedAndWithWhichTracks() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 12, selection: TrackSelection(audio: 2, subtitle: 3), quality: QualityChoice(id: "hi", range: .sdr)))
        await h.waitFor(.engineReady(Epoch(1)))
        XCTAssertEqual(h.requests.last?.startAt, 12, "a stream can begin where it is wanted instead of at the start and a jump after it")
        XCTAssertEqual(h.requests.last?.selection, TrackSelection(audio: 2, subtitle: 3), "a server's transcode has its tracks in the address")
        h.engine.perform(.play(Epoch(1)))
        h.engine.perform(.prepareSwap(Epoch(2), QualityChoice(id: "lo", range: .sdr), startAt: 15, selection: TrackSelection(audio: 2, subtitle: 3)))
        await h.waitFor(.swapPrepared(Epoch(2)))
        XCTAssertEqual(h.requests.last?.startAt, 15)
        XCTAssertEqual(h.requests.last?.quality?.id, "lo")
    }

    func testAReplacementBeginsWhereThePlayerIsAndNotWhereTheLastTickWas() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 1.4 }
        h.engine.perform(.prepareSwap(Epoch(2), QualityChoice(id: "lo", range: .sdr), startAt: 0, selection: none))
        await h.waitFor(.swapPrepared(Epoch(2)))
        let playerIsAt = h.player.currentTime().seconds
        // The reducer knows the position of the last tick (up to half a second old); the engine reads the player itself.
        h.engine.perform(.commitSwap(Epoch(2), replacing: Epoch(1), at: playerIsAt - 0.4, selection: none))
        await h.waitFor(.swapFinished(Epoch(2)))
        XCTAssertEqual(h.player.currentTime().seconds, playerIsAt, accuracy: 0.15, "no half second that was seen twice")
    }

    func testAnItemThatIsOnAPlayerAlreadyIsRefusedInsteadOfCrashingTheProcess() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        let onThePlayer = try XCTUnwrap(h.player.currentItem)
        // AVFoundation raises NSInvalidArgumentException for an item on a second player, and nothing in Swift catches it.
        h.make = { _, _ in onThePlayer }
        h.engine.perform(.prepareSwap(Epoch(2), QualityChoice(id: "lo", range: .sdr), startAt: 0, selection: none))
        let failed = await h.wait { h.events.contains { if case .swapFailed(Epoch(2), _) = $0 { return true } else { return false } } }
        XCTAssertTrue(failed, "events: \(h.events)")
    }

    // MARK: - Seeking

    func testASeekLandsAndIsReportedWithItsToken() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 12))
        let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(1)))
        XCTAssertTrue(landed, "events: \(h.events)")
        XCTAssertEqual(h.player.currentTime().seconds, 12, accuracy: 0.2, "zero tolerance: the target, not the nearest keyframe")
    }

    func testANewerSeekSupersedesAnOlderOneAndOnlyTheNewerIsReported() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 5))
        h.engine.perform(.seek(Epoch(1), SeekToken(2), to: 20))
        let landed = await h.waitFor(.seekFinished(Epoch(1), SeekToken(2)))
        XCTAssertTrue(landed, "events: \(h.events)")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(h.events.contains(.seekFinished(Epoch(1), SeekToken(1))), "the older jump never landed; reporting it would resume playback at a place the viewer left")
        XCTAssertEqual(h.player.currentTime().seconds, 20, accuracy: 0.2)
    }

    func testASeekThatIsInterruptedWithoutBeingSupersededIsNotLeftHanging() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 5))
        // Something that is not the reducer moves the player in the same instant. AVPlayer ends the engine's seek with `finished == false`, yet no newer
        // seek of the reducer's exists: without an answer the reducer waits in `.seeking` for good.
        await h.player.seek(to: CMTime(seconds: 25, preferredTimescale: 600))
        let answered = await h.wait { h.events.contains(.seekFinished(Epoch(1), SeekToken(1))) || h.events.contains { if case .engineFailed = $0 { return true } else { return false } } }
        XCTAssertTrue(answered, "events: \(h.events)")
        XCTAssertEqual(h.player.currentTime().seconds, 5, accuracy: 0.2, "the seek that was asked for is the one that is carried out")
    }

    func testAJumpBeyondTheEndOfTheItemLandsAtItsEnd() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.seek(Epoch(1), SeekToken(1), to: 5_000))   // the film has 30 s
        let landed = await h.wait { h.events.contains(.seekFinished(Epoch(1), SeekToken(1))) || h.events.contains { if case .engineFailed = $0 { return true } else { return false } } }
        XCTAssertTrue(landed, "events: \(h.events)")
        XCTAssertTrue(h.events.contains(.seekFinished(Epoch(1), SeekToken(1))), "a target past the end is no failure of the session: \(h.events)")
        XCTAssertLessThanOrEqual(h.player.currentTime().seconds, 30.1)
        XCTAssertGreaterThan(h.player.currentTime().seconds, 29, "it went to the end")
    }

    func testAStartPositionBeyondTheEndOfTheItemIsNoFailureEither() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 5_000, selection: none, quality: nil))
        let ready = await h.wait { h.events.contains(.engineReady(Epoch(1))) || h.events.contains { if case .engineFailed = $0 { return true } else { return false } } }
        XCTAssertTrue(ready, "events: \(h.events)")
        XCTAssertTrue(h.events.contains(.engineReady(Epoch(1))), "events: \(h.events)")
    }

    // MARK: - The default applier on a real group

    /// The movie with the English and the German track, as an item with its group.
    private func itemWithTwoAudioTracks(_ directory: URL) async throws -> (item: AVPlayerItem, group: AVMediaSelectionGroup) {
        let url = try await TestMedia.silentMovieWithTwoAudioTracks(seconds: 10, in: directory, name: "two")
        let item = AVPlayerItem(url: url)
        let loaded = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loaded)
        XCTAssertEqual(group.options.count, 2, "English and German")
        return (item, group)
    }

    private func selected(_ item: AVPlayerItem, _ group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        item.currentMediaSelection.selectedMediaOption(in: group)
    }

    func testTheDefaultApplierSelectsTheAudioOptionAtTheNumber() async throws {
        let directory = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (item, group) = try await itemWithTwoAudioTracks(directory)
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 1))
        XCTAssertEqual(selected(item, group)?.extendedLanguageTag, "de")
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 0))
        XCTAssertEqual(selected(item, group)?.extendedLanguageTag, "en")
    }

    func testChoosingNothingAfterAChoiceGoesBackToWhatAVFoundationPicksByItself() async throws {
        let directory = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (item, group) = try await itemWithTwoAudioTracks(directory)
        let byItself = selected(item, group)
        // The other option than the one it picks (what is picked depends on the language of the machine the test runs on).
        let other = try XCTUnwrap(group.options.firstIndex { $0 != byItself })
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: other))
        XCTAssertNotEqual(selected(item, group), byItself, "the viewer's choice is in force")
        // An explicit choice stays in force until the automatic choice is asked for again (AVPlayer.h): without that call, the state machine says "default"
        // and the player plays the German.
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: nil))
        XCTAssertEqual(selected(item, group), byItself)
    }

    func testANumberTheStreamHasNoOptionForChangesNothing() async throws {
        let directory = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (item, group) = try await itemWithTwoAudioTracks(directory)
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 1))
        let chosen = selected(item, group)
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 7))
        XCTAssertEqual(selected(item, group), chosen, "what the viewer had stays")
    }

    func testTheEngineAppliesTheTracksOfALoadAndOfALaterChangeToTheRealGroup() async throws {
        let h = try harness()
        h.files["film"] = try await TestMedia.silentMovieWithTwoAudioTracks(seconds: 20, in: h.directory, name: "film-two")
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: TrackSelection(audio: 1), quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        let item = try XCTUnwrap(h.player.currentItem)
        let loaded = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loaded)
        XCTAssertEqual(selected(item, group)?.extendedLanguageTag, "de", "the track of the load is in force when the session is ready")
        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 0)))
        let changed = await h.wait { self.selected(item, group)?.extendedLanguageTag == "en" }
        XCTAssertTrue(changed)
    }

    // MARK: - Tracks

    func testTrackChangesAreAppliedInTheOrderTheyWereAskedFor() async throws {
        var applied: [TrackSelection] = []
        // The first is slow and the second quick: tasks that do not wait for each other finish them the wrong way round.
        let h = try harness(applier: { _, selection in
            if selection.audio == 1 { try? await Task.sleep(nanoseconds: 300_000_000) }
            applied.append(selection)
        })
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        applied.removeAll()
        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 1)))
        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 2)))
        await h.wait { applied.contains(TrackSelection(audio: 2)) }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(applied.last, TrackSelection(audio: 2), "applied: \(applied)")
    }

    func testATrackChangeForAnItemThatIsGoneIsNotApplied() async throws {
        var appliedTo: [AVPlayerItem] = []
        let h = try harness(applier: { item, _ in appliedTo.append(item) })
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        let first = try XCTUnwrap(h.player.currentItem)
        appliedTo.removeAll()
        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 1)))
        h.engine.perform(.load(Epoch(2), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(2)))
        XCTAssertFalse(appliedTo.contains { $0 === first }, "the viewer had moved on to another session before the change was carried out")
    }

    // MARK: - Making a replacement before breaking the running session

    func testAReplacementIsReadyWhileTheRunningItemPlaysOn() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.4 }
        h.engine.perform(.prepareSwap(Epoch(2), QualityChoice(id: "lo", range: .sdr), startAt: 1, selection: none))
        let prepared = await h.waitFor(.swapPrepared(Epoch(2)))
        XCTAssertTrue(prepared, "events: \(h.events)")
        XCTAssertEqual((h.player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent, "film.m4a", "the running item is not touched")
        XCTAssertGreaterThan(h.player.rate, 0, "and it still plays")
        XCTAssertEqual(h.provided.last?.1?.id, "lo")
    }

    func testTheReplacementTakesOverAtThePositionOfThatMomentAndWaitsForPlay() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        h.engine.perform(.prepareSwap(Epoch(2), QualityChoice(id: "lo", range: .sdr), startAt: 0, selection: none))
        await h.waitFor(.swapPrepared(Epoch(2)))
        h.engine.perform(.commitSwap(Epoch(2), replacing: Epoch(1), at: 12, selection: none))
        let finished = await h.waitFor(.swapFinished(Epoch(2)))
        XCTAssertTrue(finished, "events: \(h.events)")
        XCTAssertEqual((h.player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent, "film-lo.m4a")
        XCTAssertEqual(h.player.currentTime().seconds, 12, accuracy: 0.2)
        XCTAssertEqual(h.player.rate, 0, "a session starts paused; the reducer's play sets it going")

        h.clearEvents()
        h.engine.perform(.play(Epoch(2)))
        let playsOn = await h.wait { (h.lastTick(of: Epoch(2)) ?? 0) > 12.4 }
        XCTAssertTrue(playsOn, "events: \(h.events)")
        XCTAssertTrue(h.ticks(of: Epoch(1)).isEmpty, "the old session says nothing any more")
    }

    func testADiscardedReplacementLeavesTheRunningItemAloneAndIsNeverReported() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        h.engine.perform(.prepareSwap(Epoch(2), QualityChoice(id: "lo", range: .sdr), startAt: 0, selection: none))
        h.engine.perform(.discardSwap(Epoch(2)))
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(h.events.contains(.swapPrepared(Epoch(2))), "events: \(h.events)")
        XCTAssertEqual((h.player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent, "film.m4a")
        XCTAssertGreaterThan(h.player.rate, 0)
    }

    func testAReplacementThatCannotBeMadeIsReportedAndTheRunningItemPlaysOn() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        h.make = { _, _ in throw EngineHarness.Failure.noItem("lo") }
        h.engine.perform(.prepareSwap(Epoch(2), QualityChoice(id: "lo", range: .sdr), startAt: 0, selection: none))
        let failed = await h.wait { h.events.contains { if case .swapFailed(Epoch(2), _) = $0 { return true } else { return false } } }
        XCTAssertTrue(failed, "events: \(h.events)")
        XCTAssertFalse(h.events.contains { if case .engineFailed = $0 { return true } else { return false } }, "the running session did not fail")
        XCTAssertGreaterThan(h.player.rate, 0)
    }

    func testAReplacementWhoseItemFailsToLoadIsAFailedSwapNotAFailedPlayback() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        h.make = { _, _ in AVPlayerItem(url: h.directory.appendingPathComponent("missing.m4a")) }
        h.engine.perform(.prepareSwap(Epoch(2), QualityChoice(id: "lo", range: .sdr), startAt: 0, selection: none))
        let failed = await h.wait { h.events.contains { if case .swapFailed(Epoch(2), _) = $0 { return true } else { return false } } }
        XCTAssertTrue(failed, "events: \(h.events)")
        XCTAssertFalse(h.events.contains { if case .engineFailed = $0 { return true } else { return false } })
        XCTAssertEqual((h.player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent, "film.m4a")
    }

    func testTakingOverFromASessionThatIsNotThereIsAFailureNotSilence() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.commitSwap(Epoch(5), replacing: Epoch(1), at: 3, selection: none))
        let reported = await h.wait { h.events.contains { if case .engineFailed(Epoch(5), _) = $0 { return true } else { return false } } }
        XCTAssertTrue(reported, "the reducer waits in .switching for an answer; events: \(h.events)")
    }

    // MARK: - Failing, stopping, being replaced

    func testAnItemThatCannotBeLoadedFailsTheSessionWithItsEpoch() async throws {
        let h = try harness()
        h.make = { _, _ in AVPlayerItem(url: h.directory.appendingPathComponent("missing.m4a")) }
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        let failed = await h.wait { h.events.contains { if case .engineFailed(Epoch(1), _) = $0 { return true } else { return false } } }
        XCTAssertTrue(failed, "events: \(h.events)")
        XCTAssertFalse(h.events.contains(.engineReady(Epoch(1))))
    }

    func testAProviderThatThrowsFailsTheSessionWithItsEpoch() async throws {
        let h = try harness()
        h.files = [:]
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        let failed = await h.wait { h.events.contains { if case .engineFailed(Epoch(1), _) = $0 { return true } else { return false } } }
        XCTAssertTrue(failed, "events: \(h.events)")
    }

    func testAnItemThatFailsWhileItPlaysIsReported() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        let item = try XCTUnwrap(h.player.currentItem)
        // What AVFoundation posts when the stream dies under a playing item (the -19602 of 2026-10-07 arrived this way).
        let error = NSError(domain: "CoreMediaErrorDomain", code: -19602, userInfo: [NSLocalizedDescriptionKey: "test"])
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: error])
        let failed = await h.wait { h.events.contains { if case .engineFailed(Epoch(1), _) = $0 { return true } else { return false } } }
        XCTAssertTrue(failed, "events: \(h.events)")
        if case let .engineFailed(_, reason)? = h.events.last(where: { if case .engineFailed = $0 { return true } else { return false } }) {
            XCTAssertTrue(reason.contains("-19602"), "the reason keeps the code: \(reason)")
        }
    }

    func testAnItemThatTheProviderReturnsLateForAReplacedLoadIsDropped() async throws {
        let h = try harness()
        var releaseFirst: CheckedContinuation<Void, Never>?
        var calls = 0
        h.make = { [unowned h] source, _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { releaseFirst = $0 } }
            return AVPlayerItem(url: h.files[source.id]!)
        }
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.wait { releaseFirst != nil }
        h.engine.perform(.load(Epoch(2), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(2)))
        let current = h.player.currentItem
        releaseFirst?.resume()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(h.events.contains(.engineReady(Epoch(1))), "events: \(h.events)")
        XCTAssertTrue(h.player.currentItem === current, "the late item must not replace the one of the newer load")
    }

    func testStopEndsTheSessionAndSilencesTheEngine() async throws {
        let h = try harness()
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: none, quality: nil))
        await h.waitFor(.engineReady(Epoch(1)))
        h.engine.perform(.play(Epoch(1)))
        await h.wait { (h.lastTick(of: Epoch(1)) ?? 0) > 0.4 }
        h.engine.perform(.stop(Epoch(1)))
        XCTAssertNil(h.player.currentItem)
        h.clearEvents()
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(h.events.isEmpty, "events after stop: \(h.events)")
    }
}
