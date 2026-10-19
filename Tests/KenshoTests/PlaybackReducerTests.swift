import XCTest
@testable import Kensho

final class PlaybackReducerTests: XCTestCase {
    private let source = MediaSource(id: "film", range: .dolbyVision)
    private let hi = QualityChoice(id: "original", range: .dolbyVision)
    private let lo = QualityChoice(id: "low", range: .dolbyVision)
    private let sdr = QualityChoice(id: "sdr", range: .sdr)

    private func run(_ events: [PlaybackEvent], from start: PlaybackState = PlaybackState()) -> (PlaybackState, [PlaybackEffect]) {
        var s = start
        var all: [PlaybackEffect] = []
        for e in events {
            let r = PlaybackReducer.reduce(s, e)
            s = r.state
            all += r.effects
        }
        return (s, all)
    }

    /// Loaded (epoch 1), ready, playing.
    private func playing() -> PlaybackState {
        let (s, _) = run([
            .load(source, startAt: 0, selection: TrackSelection(audio: 1), quality: hi),
            .engineReady(Epoch(1)),
        ])
        return s
    }

    private func isSwapEffect(_ effect: PlaybackEffect) -> Bool {
        switch effect {
        case .prepareSwap, .commitSwap, .discardSwap: return true
        default: return false
        }
    }

    private func isApplySelection(_ effect: PlaybackEffect) -> Bool {
        if case .applySelection = effect { return true } else { return false }
    }

    // MARK: - Loading, playing, pausing

    func testLoadThenReadyStartsPlayback() {
        let (s, fx) = run([
            .load(source, startAt: 5, selection: TrackSelection(), quality: hi),
            .engineReady(Epoch(1)),
        ])
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(s.position, 5)
        XCTAssertEqual(fx.last, .play(Epoch(1)))
    }

    func testStaleReadyFromReplacedLoadIsDropped() {
        let (s, fx) = run([
            .load(source, startAt: 0, selection: TrackSelection(), quality: hi),
            .load(source, startAt: 0, selection: TrackSelection(), quality: hi),
            .engineReady(Epoch(1)),
        ])
        XCTAssertEqual(s.epoch, Epoch(2))
        XCTAssertEqual(s.phase, .loading)
        XCTAssertFalse(fx.contains(.play(Epoch(1))))
    }

    func testPauseBeforeReadyKeepsItPaused() {
        let (s, fx) = run([
            .load(source, startAt: 0, selection: TrackSelection(), quality: hi),
            .pause,
            .engineReady(Epoch(1)),
        ])
        XCTAssertEqual(s.phase, .paused)
        XCTAssertFalse(fx.contains(.play(Epoch(1))))
    }

    func testPauseAndPlayAreEffectsOfTheLiveSession() {
        let (paused, pauseFx) = run([.pause], from: playing())
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(pauseFx, [.pause(Epoch(1))])
        let (resumed, playFx) = run([.play], from: paused)
        XCTAssertEqual(resumed.phase, .playing)
        XCTAssertEqual(playFx, [.play(Epoch(1))])
    }

    // MARK: - Seeking

    func testLaterSeekSupersedesEarlierAndOldCompletionIsIgnored() {
        var (s, _) = run([.seek(to: 100)], from: playing())
        let first = s.seekToken
        (s, _) = run([.seek(to: 200)], from: s)
        let second = s.seekToken
        XCTAssertNotEqual(first, second)
        let (afterOld, fxOld) = run([.seekFinished(Epoch(1), first)], from: s)
        XCTAssertEqual(afterOld.phase, .seeking)
        XCTAssertTrue(fxOld.isEmpty)
        let (afterNew, fxNew) = run([.seekFinished(Epoch(1), second)], from: s)
        XCTAssertEqual(afterNew.phase, .playing)
        XCTAssertEqual(fxNew, [.play(Epoch(1))])
    }

    func testSeekWhilePausedDoesNotResume() {
        var (s, _) = run([.pause, .seek(to: 50)], from: playing())
        let token = s.seekToken
        let r = PlaybackReducer.reduce(s, .seekFinished(Epoch(1), token))
        s = r.state
        XCTAssertEqual(s.phase, .paused)
        XCTAssertTrue(r.effects.isEmpty)
    }

    func testTickDuringSeekDoesNotMovePositionBack() {
        let (s, _) = run([.seek(to: 300), .engineTick(Epoch(1), position: 12)], from: playing())
        XCTAssertEqual(s.position, 300)
    }

    func testTrackChangeDuringSeekWaitsUntilSteady() {
        var (s, fx) = run([.seek(to: 90), .selectAudio(2)], from: playing())
        XCTAssertFalse(fx.contains(where: isApplySelection))
        let token = s.seekToken
        (s, fx) = run([.seekFinished(Epoch(1), token)], from: s)
        XCTAssertEqual(fx.first, .applySelection(Epoch(1), TrackSelection(audio: 2)))
        XCTAssertEqual(fx.last, .play(Epoch(1)))
    }

    func testTrackChangeWhenSteadyAppliesImmediately() {
        let (_, fx) = run([.selectSubtitle(3)], from: playing())
        XCTAssertEqual(fx, [.applySelection(Epoch(1), TrackSelection(audio: 1, subtitle: 3))])
    }

    // MARK: - Quality: a replacement is made while the running session plays on

    func testQualityRequestPreparesAReplacementAndTheRunningSessionPlaysOn() {
        let (s, fx) = run([.engineTick(Epoch(1), position: 42), .requestQuality(lo, now: 100)], from: playing())
        XCTAssertEqual(s.phase, .playing, "nothing is interrupted")
        XCTAssertEqual(s.epoch, Epoch(1), "the running session is still the live one")
        XCTAssertEqual(s.swap?.epoch, Epoch(2), "the replacement has an epoch of its own")
        XCTAssertEqual(s.quality, hi, "the quality changes when the replacement takes over, not when it is asked for")
        XCTAssertEqual(fx, [.prepareSwap(Epoch(2), lo, startAt: 42, selection: TrackSelection(audio: 1))])
    }

    func testTheRunningSessionsTicksAndStallsStillCountWhileTheReplacementIsPrepared() {
        var (s, _) = run([.requestQuality(lo, now: 100)], from: playing())
        (s, _) = run([.engineTick(Epoch(1), position: 50), .engineStalled(Epoch(1))], from: s)
        XCTAssertEqual(s.position, 50, "the picture is still moving")
        XCTAssertEqual(s.phase, .buffering, "and the stall is the running session's")
        (s, _) = run([.engineRecovered(Epoch(1)), .engineTick(Epoch(1), position: 55)], from: s)
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(s.position, 55)
    }

    func testTheReplacementBeginsWhereThePlaybackIsWhenItTakesOver() {
        let (s, fx) = run([
            .requestQuality(lo, now: 100),
            .engineTick(Epoch(1), position: 80),
            .swapPrepared(Epoch(2)),
        ], from: playing())
        XCTAssertEqual(s.phase, .switching)
        XCTAssertEqual(s.epoch, Epoch(2), "the replacement is the live session now")
        XCTAssertEqual(s.quality, lo)
        XCTAssertNil(s.swap)
        XCTAssertEqual(fx.last, .commitSwap(Epoch(2), replacing: Epoch(1), at: 80, selection: TrackSelection(audio: 1)), "at 80, not at 0 where it was asked for")
    }

    func testTheReplacementPlaysWhenItIsAtItsPosition() {
        let (s, fx) = run([.requestQuality(lo, now: 100), .swapPrepared(Epoch(2)), .swapFinished(Epoch(2))], from: playing())
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(fx.last, .play(Epoch(2)))
    }

    func testAPausedPlaybackStaysPausedAcrossASwap() {
        let (s, fx) = run([.pause, .requestQuality(lo, now: 100), .swapPrepared(Epoch(2)), .swapFinished(Epoch(2))], from: playing())
        XCTAssertEqual(s.phase, .paused)
        XCTAssertFalse(fx.contains(.play(Epoch(2))))
    }

    func testOldSessionEventsAfterTheTakeOverAreDropped() {
        let (s, _) = run([
            .requestQuality(lo, now: 100),
            .swapPrepared(Epoch(2)),
            .engineFailed(Epoch(1), reason: "old session torn down"),
            .engineStalled(Epoch(1)),
            .engineTick(Epoch(1), position: 999),
        ], from: playing())
        XCTAssertEqual(s.phase, .switching)
        XCTAssertNotEqual(s.position, 999)
    }

    func testAReplacementThatCannotBeMadeLeavesTheRunningSessionAlone() {
        let (s, fx) = run([.requestQuality(lo, now: 100), .swapFailed(Epoch(2), reason: "server")], from: playing())
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(s.epoch, Epoch(1))
        XCTAssertNil(s.swap)
        XCTAssertEqual(s.quality, hi)
        XCTAssertFalse(fx.contains(where: { if case .commitSwap = $0 { return true } else { return false } }))
    }

    func testAReportOfAnotherReplacementIsIgnored() {
        let (s, fx) = run([.requestQuality(lo, now: 100), .swapPrepared(Epoch(7)), .swapFailed(Epoch(7), reason: "x")], from: playing())
        XCTAssertNotNil(s.swap, "the replacement that was asked for is still on its way")
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(fx.count, 1, "only the request itself")
    }

    func testOnlyOneReplacementAtATime() {
        let (s, fx) = run([.requestQuality(lo, now: 100), .requestQuality(sdr, now: 200), .requestQuality(hi, now: 300)], from: playing())
        XCTAssertEqual(fx.filter { if case .prepareSwap = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(s.swap?.quality, lo)
    }

    func testQualityCooldownBlocksFlapping() {
        var (s, _) = run([.requestQuality(lo, now: 100), .swapPrepared(Epoch(2)), .swapFinished(Epoch(2))], from: playing())
        let (_, blocked) = run([.requestQuality(hi, now: 110)], from: s)
        XCTAssertTrue(blocked.isEmpty)
        (s, _) = run([.requestQuality(hi, now: 131)], from: s)
        XCTAssertNotNil(s.swap, "after the cooldown a replacement is prepared again")
    }

    func testQualityChangeAcrossVideoRangeIsRefused() {
        let (s, fx) = run([.requestQuality(sdr, now: 100)], from: playing())
        XCTAssertEqual(s.phase, .playing)
        XCTAssertNil(s.swap)
        XCTAssertTrue(fx.isEmpty)
    }

    func testQualityIsRefusedWhileSeekingOrLoading() {
        let (seeking, seekFx) = run([.seek(to: 10), .requestQuality(lo, now: 100)], from: playing())
        XCTAssertEqual(seeking.phase, .seeking)
        XCTAssertFalse(seekFx.contains(where: isSwapEffect))
        let (loading, loadFx) = run([.load(source, startAt: 0, selection: TrackSelection(), quality: hi), .requestQuality(lo, now: 100)])
        XCTAssertEqual(loading.phase, .loading)
        XCTAssertFalse(loadFx.contains(where: isSwapEffect))
    }

    func testAReplacementReadyDuringAJumpTakesOverWhenTheJumpHasLanded() {
        var (s, fx) = run([.requestQuality(lo, now: 100), .seek(to: 500), .swapPrepared(Epoch(2))], from: playing())
        XCTAssertEqual(s.epoch, Epoch(1), "not in the middle of a jump")
        XCTAssertFalse(fx.contains(where: { if case .commitSwap = $0 { return true } else { return false } }))
        let token = s.seekToken
        (s, fx) = run([.seekFinished(Epoch(1), token)], from: s)
        XCTAssertEqual(s.phase, .switching)
        XCTAssertEqual(fx, [.commitSwap(Epoch(2), replacing: Epoch(1), at: 500, selection: TrackSelection(audio: 1))], "from where the jump landed, and the old session is not set playing first")
    }

    func testSeekAfterTheTakeOverIsAppliedWhenTheReplacementIsAtItsPosition() {
        let (s, fx) = run([
            .requestQuality(lo, now: 100),
            .swapPrepared(Epoch(2)),
            .seek(to: 500),
            .swapFinished(Epoch(2)),
        ], from: playing())
        XCTAssertEqual(s.phase, .seeking)
        XCTAssertEqual(fx.last, .seek(Epoch(2), s.seekToken, to: 500))
    }

    func testATrackChosenWhileAReplacementIsPreparedIsAppliedToBoth() {
        let (s, fx) = run([.requestQuality(lo, now: 100), .selectAudio(2), .swapPrepared(Epoch(2))], from: playing())
        XCTAssertTrue(fx.contains(.applySelection(Epoch(1), TrackSelection(audio: 2))), "the running session has it at once")
        XCTAssertEqual(fx.last, .commitSwap(Epoch(2), replacing: Epoch(1), at: 0, selection: TrackSelection(audio: 2)), "and the replacement begins with it")
        XCTAssertEqual(s.selection, TrackSelection(audio: 2))
    }

    // MARK: - A session that dies while a replacement is on its way

    func testARunningSessionThatDiesWhileAReplacementIsPreparedWaitsForIt() {
        let (s, _) = run([.requestQuality(lo, now: 100), .engineFailed(Epoch(1), reason: "stream died")], from: playing())
        XCTAssertEqual(s.phase, .switching, "not failed: the replacement is the way on")
        let (taken, fx) = run([.swapPrepared(Epoch(2))], from: s)
        XCTAssertEqual(taken.epoch, Epoch(2))
        XCTAssertEqual(fx.last, .commitSwap(Epoch(2), replacing: Epoch(1), at: 0, selection: TrackSelection(audio: 1)))
    }

    func testIfTheReplacementFailsToo_ThePlaybackFailsWithTheFirstReason() {
        let (s, _) = run([.requestQuality(lo, now: 100), .engineFailed(Epoch(1), reason: "stream died"), .swapFailed(Epoch(2), reason: "no server")], from: playing())
        XCTAssertEqual(s.phase, .failed("stream died"))
    }

    func testAReadyReplacementDoesNotWaitForAJumpOnASessionThatDied() {
        let (s, fx) = run([
            .requestQuality(lo, now: 100), .seek(to: 500), .swapPrepared(Epoch(2)),
            .engineFailed(Epoch(1), reason: "stream died"),
        ], from: playing())
        XCTAssertEqual(s.epoch, Epoch(2))
        XCTAssertEqual(s.phase, .switching)
        XCTAssertEqual(fx.last, .commitSwap(Epoch(2), replacing: Epoch(1), at: 500, selection: TrackSelection(audio: 1)))
    }

    // MARK: - Loading and stopping with a replacement on its way

    func testLoadingSomethingElseThrowsTheReplacementAway() {
        let (s, fx) = run([.requestQuality(lo, now: 100), .load(source, startAt: 0, selection: TrackSelection(), quality: hi)], from: playing())
        XCTAssertNil(s.swap)
        XCTAssertTrue(fx.contains(.discardSwap(Epoch(2))))
        // And the late report of the replacement is nothing.
        let (after, _) = run([.swapPrepared(Epoch(2))], from: s)
        XCTAssertEqual(after.phase, .loading)
        XCTAssertNotEqual(after.epoch, Epoch(2), "the new load has an epoch of its own")
    }

    func testStoppingThrowsTheReplacementAwayToo() {
        let (s, fx) = run([.requestQuality(lo, now: 100), .stop], from: playing())
        XCTAssertEqual(s.phase, .stopped)
        XCTAssertEqual(fx.suffix(2), [.discardSwap(Epoch(2)), .stop(Epoch(1))])
    }

    // MARK: - Stalls, stopping, failing

    func testStallAndRecovery() {
        var (s, _) = run([.engineStalled(Epoch(1))], from: playing())
        XCTAssertEqual(s.phase, .buffering)
        (s, _) = run([.engineRecovered(Epoch(1))], from: s)
        XCTAssertEqual(s.phase, .playing)
    }

    func testStopInvalidatesLateEngineEvents() {
        let (s, fx) = run([.stop, .engineReady(Epoch(1)), .engineFailed(Epoch(1), reason: "x")], from: playing())
        XCTAssertEqual(s.phase, .stopped)
        XCTAssertEqual(fx, [.stop(Epoch(1))])
    }

    func testIntentsAreIgnoredAfterFailure() {
        let (s, fx) = run([.engineFailed(Epoch(1), reason: "boom"), .play, .seek(to: 5)], from: playing())
        XCTAssertEqual(s.phase, .failed("boom"))
        XCTAssertTrue(fx.isEmpty)
    }

    // MARK: - What the viewer wants survives what the player does

    func testAPauseOrPlayDuringAFailureIsRememberedAndNothingElse() {
        var (s, fx) = run([.engineFailed(Epoch(1), reason: "boom"), .pause], from: playing())
        XCTAssertEqual(s.phase, .failed("boom"))
        XCTAssertFalse(s.wantsPlay, "the viewer pressed pause while the stream was being made again")
        XCTAssertTrue(fx.isEmpty, "there is nothing to pause: the engine has no session")
        (s, fx) = run([.play], from: s)
        XCTAssertTrue(s.wantsPlay)
        XCTAssertTrue(fx.isEmpty)
    }

    func testAPauseWhileTheItemLoadsTellsTheEngineToHoldAndTheItBeginsPaused() {
        let (loading, _) = run([.load(source, startAt: 0, selection: TrackSelection(), quality: hi)])
        XCTAssertEqual(loading.phase, .loading)
        let (paused, fx) = run([.pause], from: loading)
        XCTAssertFalse(paused.wantsPlay)
        XCTAssertEqual(paused.phase, .loading, "the item is still on its way")
        XCTAssertEqual(fx, [.pause(Epoch(1))], "an engine that plays at once (the car's) has nothing else that holds it; to one that waits it is a pause of a paused player")
        let (ready, readyFx) = run([.engineReady(Epoch(1))], from: paused)
        XCTAssertEqual(ready.phase, .paused, "and it begins paused")
        XCTAssertTrue(readyFx.isEmpty, "with no play")
    }

    func testAnIntentWithoutASessionIsStillIgnored() {
        let (s, fx) = run([.pause, .play, .seek(to: 5)])
        XCTAssertEqual(s, PlaybackState(), "nothing is loaded: there is nothing to want")
        XCTAssertTrue(fx.isEmpty)
        let (stopped, _) = run([.stop, .pause], from: playing())
        XCTAssertTrue(stopped.wantsPlay == false && stopped.phase == .stopped)
    }

    func testAReloadIsANewSessionOfTheSameSourceThatKeepsWhatTheViewerWants() {
        let paused = run([.pause], from: playing()).0
        let (s, fx) = run([.reload(startAt: 50, selection: TrackSelection(audio: 2), quality: lo)], from: paused)
        XCTAssertEqual(s.epoch, Epoch(2))
        XCTAssertEqual(s.phase, .loading)
        XCTAssertFalse(s.wantsPlay, "a load is the viewer starting something; a reload is the app making the stream again under him")
        XCTAssertEqual(s.source, source)
        XCTAssertEqual(s.position, 50)
        XCTAssertEqual(s.selection, TrackSelection(audio: 2))
        XCTAssertEqual(s.quality, lo)
        XCTAssertEqual(fx, [.load(Epoch(2), source, startAt: 50, selection: TrackSelection(audio: 2), quality: lo)])
        let (ready, readyFx) = run([.engineReady(Epoch(2))], from: s)
        XCTAssertEqual(ready.phase, .paused, "and it begins paused")
        XCTAssertFalse(readyFx.contains(.play(Epoch(2))))
    }

    func testAReloadOfAPlayingFilmPlaysWhenReady() {
        let (s, fx) = run([.reload(startAt: 10, selection: TrackSelection(), quality: hi), .engineReady(Epoch(2))], from: playing())
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(fx.last, .play(Epoch(2)))
    }

    func testAReloadAfterAFailureRecoversAndKeepsThePause() {
        let failedWhilePaused = run([.pause, .engineFailed(Epoch(1), reason: "boom")], from: playing()).0
        let (s, _) = run([.reload(startAt: 123, selection: TrackSelection(audio: 1), quality: hi), .engineReady(Epoch(2))], from: failedWhilePaused)
        XCTAssertEqual(s.phase, .paused)
        XCTAssertEqual(s.position, 123)
    }

    func testAReloadThrowsAReplacementAwayAndLeavesOldReportsStale() {
        let preparing = run([.requestQuality(lo, now: 100)], from: playing()).0
        let (s, fx) = run([.reload(startAt: 0, selection: TrackSelection(), quality: hi)], from: preparing)
        XCTAssertNil(s.swap)
        XCTAssertEqual(fx.first, .discardSwap(Epoch(2)))
        XCTAssertEqual(s.epoch, Epoch(3), "the replacement had its number; the new session has the next")
        let (late, _) = run([.swapPrepared(Epoch(2)), .engineReady(Epoch(1))], from: s)
        XCTAssertEqual(late.phase, .loading, "reports of the sessions before are dropped")
    }

    func testAReloadWithNothingLoadedDoesNothing() {
        let (s, fx) = run([.reload(startAt: 0, selection: TrackSelection(), quality: nil)])
        XCTAssertEqual(s, PlaybackState())
        XCTAssertTrue(fx.isEmpty)
        let (stopped, stopFx) = run([.stop, .reload(startAt: 0, selection: TrackSelection(), quality: nil)], from: playing())
        XCTAssertEqual(stopped.phase, .stopped, "what ended stays ended")
        XCTAssertEqual(stopFx.count, 1)
    }

    func testALoadRecoversAFailedPlaybackFromWhereItWas() {
        var (s, _) = run([.engineTick(Epoch(1), position: 123), .engineFailed(Epoch(1), reason: "boom")], from: playing())
        let position = s.position
        let (recovered, fx) = run([.load(source, startAt: position, selection: s.selection, quality: s.quality)], from: s)
        s = recovered
        XCTAssertEqual(s.phase, .loading)
        XCTAssertEqual(fx, [.load(Epoch(2), source, startAt: 123, selection: TrackSelection(audio: 1), quality: hi)])
    }
}
