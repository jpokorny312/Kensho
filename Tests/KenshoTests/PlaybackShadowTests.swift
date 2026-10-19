import XCTest
@testable import Kensho

/// A log that writes down what it is told.
private final class MemoryLog: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func write(_ line: String, tag: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append("[\(tag)] \(line)")
    }
    func contains(_ text: String) -> Bool { lines.contains { $0.contains(text) } }
    func count(_ text: String) -> Int { lines.filter { $0.contains(text) }.count }
}

@MainActor
final class PlaybackShadowTests: XCTestCase {
    private var now: TimeInterval = 1_000
    private var memory = MemoryLog()

    private func makeShadow() -> PlaybackShadow {
        memory = MemoryLog()
        return PlaybackShadow(log: KenshoLog(sinks: [memory]), clock: { [unowned self] in self.now })
    }

    private func app(
        wantsToPlay: Bool = true, waiting: Bool = false, reconnecting: Bool = false, failed: Bool = false,
        changingQuality: Bool = false, unsentJump: Bool = false, position: TimeInterval = 0, item: String = "film"
    ) -> PlaybackShadow.Observation {
        PlaybackShadow.Observation(
            wantsToPlay: wantsToPlay, isWaitingForData: waiting, isReconnecting: reconnecting, hasFailed: failed,
            isChangingQuality: changingQuality, hasUnsentJump: unsentJump, position: position, itemId: item
        )
    }

    private func startedPlaying(_ shadow: PlaybackShadow, at position: TimeInterval = 0) {
        shadow.begin(item: "film", startAt: position, quality: "original", audio: 1, subtitle: nil, reason: "initial")
        shadow.playerIsReady()
    }

    // MARK: - Following the app

    func testItFollowsAStartAndAPauseAndAJumpAndTheEnd() {
        let shadow = makeShadow()
        shadow.begin(item: "film", startAt: 30, quality: "original", audio: 2, subtitle: 3, reason: "initial")
        XCTAssertEqual(shadow.state.phase, .loading)
        XCTAssertEqual(shadow.state.selection, TrackSelection(audio: 2, subtitle: 3))
        shadow.playerIsReady()
        XCTAssertEqual(shadow.state.phase, .playing)
        shadow.pause()
        XCTAssertEqual(shadow.state.phase, .paused)
        shadow.seek(to: 600)
        XCTAssertEqual(shadow.state.phase, .seeking)
        shadow.jumpLanded()
        XCTAssertEqual(shadow.state.phase, .paused, "the viewer had paused: the jump does not resume")
        shadow.play()
        XCTAssertEqual(shadow.state.phase, .playing)
        shadow.end()
        XCTAssertEqual(shadow.state.phase, .stopped)
        XCTAssertTrue(memory.contains("end:"), "lines: \(memory.lines)")
    }

    func testTheEnginesInstructionsAreWrittenDownAndNotCarriedOut() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        XCTAssertEqual(shadow.instructions, [
            .load(Epoch(1), MediaSource(id: "film", range: .sdr), startAt: 0, selection: TrackSelection(audio: 1, subtitle: nil), quality: QualityChoice(id: "original", range: .sdr)),
            .play(Epoch(1)),
        ])
        XCTAssertTrue(memory.contains("instructs: load #1 film at 0.0 s"))
    }

    func testAStallAndItsEndMoveThePhase() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.playerStalled()
        XCTAssertEqual(shadow.state.phase, .buffering)
        shadow.playerRecovered()
        XCTAssertEqual(shadow.state.phase, .playing)
    }

    func testPlayingTheSameThingAgainIsNoEventWorthALine() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        let linesBefore = memory.lines.count
        shadow.play()
        XCTAssertTrue(memory.lines.last?.contains("no effect") == true, "lines: \(memory.lines.suffix(2))")
        XCTAssertEqual(memory.lines.count, linesBefore + 1)
        XCTAssertEqual(shadow.ignoredCount, 1)
    }

    func testTicksAreNotLoggedExceptAHeartbeatEveryTenSeconds() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        let linesBefore = memory.lines.count
        for i in 0..<10 {
            now += 0.5
            shadow.playerMoved(to: Double(i) * 0.5)
        }
        XCTAssertEqual(memory.lines.count - linesBefore, 1, "the first tick says where it is; the nine after it are within ten seconds")
        now += 11
        shadow.playerMoved(to: 20)
        XCTAssertEqual(memory.lines.count - linesBefore, 2)
        XCTAssertEqual(shadow.state.position, 20)
    }

    // MARK: - Changing the quality

    func testAQualityChangeIsPreparedWhileThePlayerPlaysOnAndTakesOver() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.playerMoved(to: 40)
        shadow.qualityChangeBegins(to: "4Mbps", reason: "two stalls")
        XCTAssertEqual(shadow.state.phase, .playing, "the old stream plays on while the other is made")
        XCTAssertNotNil(shadow.state.swap)
        shadow.playerMoved(to: 44)
        shadow.qualityChangeReady()
        XCTAssertEqual(shadow.state.phase, .switching)
        XCTAssertEqual(shadow.instructions.last, .commitSwap(Epoch(2), replacing: Epoch(1), at: 44, selection: TrackSelection(audio: 1, subtitle: nil)))
        shadow.playerIsReady()
        XCTAssertEqual(shadow.state.phase, .playing, "the new item is at its place: replacement finished, not a load")
        XCTAssertEqual(shadow.state.quality?.id, "4Mbps")
        XCTAssertTrue(memory.contains("replacement #2 is at its place"))
    }

    func testAChangeTheStateMachineWouldNotHaveBegunSaysWhyAndIsFollowedAsANewSessionWhenTheAppSwapsAnyway() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.qualityChangeBegins(to: "4Mbps", reason: "first")
        shadow.qualityChangeReady()
        shadow.playerIsReady()
        now += 10
        shadow.qualityChangeBegins(to: "2Mbps", reason: "second, ten seconds later")
        XCTAssertTrue(memory.contains("would not have started it: the last change was 10.0 s ago and the cooldown is 30.0 s"), "lines: \(memory.lines)")
        XCTAssertNil(shadow.state.swap)
        // The app swaps all the same: the state machine follows with a new session (the viewer's wish as the app keeps it: playing).
        shadow.qualityChangeReady()
        XCTAssertEqual(shadow.state.phase, .loading)
        XCTAssertEqual(shadow.state.epoch, Epoch(3))
        shadow.playerIsReady()
        XCTAssertEqual(shadow.state.phase, .playing)
    }

    func testACallOffLeavesThePlaybackAlone() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.qualityChangeBegins(to: "4Mbps", reason: "two stalls")
        shadow.qualityChangeCalledOff("the old stream recovered")
        XCTAssertNil(shadow.state.swap)
        XCTAssertEqual(shadow.state.phase, .playing)
        XCTAssertEqual(shadow.state.epoch, Epoch(1))
    }

    // MARK: - The comparison

    func testAgreementIsSilent() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        for _ in 0..<40 {
            now += 0.5
            shadow.compare(with: app())
        }
        XCTAssertFalse(memory.contains("DEVIATION"), "lines: \(memory.lines)")
        XCTAssertEqual(shadow.deviationCount, 0)
    }

    func testADisagreementOnWhatTheViewerWantsIsWrittenDownOnceItLastsAndWhenItIsOver() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        // The app has the viewer paused, the state machine does not know (a hook is missing, or the viewer's pause was lost on the way).
        shadow.compare(with: app(wantsToPlay: false))
        now += 1
        shadow.compare(with: app(wantsToPlay: false))
        XCTAssertFalse(memory.contains("DEVIATION"), "one second is a moment")
        now += 1
        shadow.compare(with: app(wantsToPlay: false))
        XCTAssertEqual(memory.count("DEVIATION wants-play"), 1, "lines: \(memory.lines)")
        XCTAssertTrue(memory.contains("the app wants to play: false; the state machine: true"))
        now += 3
        shadow.compare(with: app(wantsToPlay: false))
        XCTAssertEqual(memory.count("DEVIATION wants-play:"), 1, "not again while it goes on")
        shadow.pause()
        shadow.compare(with: app(wantsToPlay: false))
        XCTAssertTrue(memory.contains("DEVIATION wants-play is over after"), "lines: \(memory.lines)")
        XCTAssertEqual(shadow.deviationCount, 1)
    }

    func testAMomentaryDisagreementLeavesNoTrace() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.compare(with: app(wantsToPlay: false))
        now += 0.5
        shadow.pause()
        shadow.compare(with: app(wantsToPlay: false))
        now += 5
        shadow.compare(with: app(wantsToPlay: false))
        XCTAssertFalse(memory.contains("DEVIATION"), "lines: \(memory.lines)")
    }

    func testAReplacementUnderTheViewersFeetKeepsHisPauseAndTheComparisonSaysWhenTheAppResumesHim() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.pause()
        // A reconnect: the app puts a new item in and, as its replaceItem always does, plays on (isPlaying = true).
        shadow.begin(item: "film", startAt: 50, quality: "original", audio: 1, subtitle: nil, reason: "reconnect", startsPlayback: false)
        XCTAssertFalse(shadow.state.wantsPlay, "the viewer paused; nothing he did since asks for playback")
        XCTAssertTrue(memory.contains("the viewer had paused: that stays"))
        shadow.playerIsReady()
        XCTAssertEqual(shadow.state.phase, .paused)
        for _ in 0..<8 {
            now += 0.5
            shadow.compare(with: app(wantsToPlay: true, position: 50))
        }
        XCTAssertTrue(memory.contains("DEVIATION wants-play: the app wants to play: true; the state machine: false"), "lines: \(memory.lines)")
        XCTAssertEqual(memory.count("DEVIATION phase"), 0, "one cause, one line")
    }

    func testAnAppThatPlaysOnAfterReplacingTheStreamOfAPausedViewerIsNamedAsTheCauseAndReportedWhenItLasts() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.pause()
        shadow.begin(item: "film", startAt: 50, quality: "original", audio: 1, subtitle: nil, reason: "rebuild", startsPlayback: false)
        // The app's replaceItem sets isPlaying = true as its last line.
        shadow.replacementPlays(true)
        XCTAssertTrue(memory.contains("the app plays on after replacing the stream"), "lines: \(memory.lines)")
        XCTAssertFalse(memory.contains("DEVIATION"), "a line that names the cause and no loss yet - the app may set the pause back: \(memory.lines)")
        XCTAssertEqual(shadow.deviationCount, 0)
        // It does not: the viewer is playing again, which he did not ask for.
        shadow.playerIsReady()
        for _ in 0..<6 {
            now += 0.5
            shadow.compare(with: app(wantsToPlay: true, position: 50))
        }
        XCTAssertTrue(memory.contains("DEVIATION wants-play"), "lines: \(memory.lines)")
        XCTAssertTrue(memory.contains("replaced under the viewer's pause"), "and it says why: \(memory.lines)")
        XCTAssertEqual(shadow.deviationCount, 1, "one cause, one line")
    }

    func testAnAppThatSetsThePauseBackAtOnceLosesTheViewerNothing() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.pause()
        shadow.begin(item: "film", startAt: 50, quality: "original", audio: 1, subtitle: nil, reason: "rebuild", startsPlayback: false)
        shadow.replacementPlays(true)
        // What the Apple TV does after the trip through the background: player.pause() a moment after the replacement.
        now += 0.016
        shadow.appPauses()
        XCTAssertTrue(memory.contains("set the viewer's pause back"), "lines: \(memory.lines)")
        shadow.playerIsReady()
        XCTAssertEqual(shadow.state.phase, .paused)
        for _ in 0..<8 {
            now += 0.5
            shadow.compare(with: app(wantsToPlay: false, position: 50))
        }
        XCTAssertFalse(memory.contains("DEVIATION"), "lines: \(memory.lines)")
        XCTAssertEqual(shadow.deviationCount, 0)
    }

    func testAPauseOfTheViewerAfterTheReplacementIsNotTakenForTheAppsRepair() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.pause()
        shadow.begin(item: "film", startAt: 50, quality: "original", audio: 1, subtitle: nil, reason: "rebuild", startsPlayback: false)
        shadow.replacementPlays(true)
        // He notices that it plays and pauses again. The hook cannot tell that from the app's own pause; the call the app's repair makes is another.
        now += 3
        shadow.pause()
        XCTAssertFalse(memory.contains("set the viewer's pause back"), "the app did not do that: \(memory.lines)")
        shadow.playerIsReady()
        for _ in 0..<8 {
            now += 0.5
            shadow.compare(with: app(wantsToPlay: false, position: 50))
        }
        XCTAssertFalse(memory.contains("DEVIATION"), "lines: \(memory.lines)")
    }

    func testTheViewerPlayingAfterTheReplacementEndsTheCause() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.pause()
        shadow.begin(item: "film", startAt: 50, quality: "original", audio: 1, subtitle: nil, reason: "rebuild", startsPlayback: false)
        shadow.replacementPlays(true)
        shadow.play()           // he wants it now
        shadow.playerIsReady()
        for _ in 0..<8 {
            now += 0.5
            shadow.compare(with: app(wantsToPlay: true, position: 50))
        }
        XCTAssertFalse(memory.contains("DEVIATION"), "lines: \(memory.lines)")
        XCTAssertFalse(memory.contains("set the viewer's pause back"), "he pressed play; the app did not take anything back")
    }

    func testAReplacementThatLeavesTheViewerWhereHeWasIsNoDeviation() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.begin(item: "film", startAt: 50, quality: "original", audio: 1, subtitle: nil, reason: "reconnect", startsPlayback: false)
        shadow.replacementPlays(true)       // playing before, playing after
        shadow.pause()
        shadow.replacementPlays(false)      // paused, and the app leaves it so
        XCTAssertFalse(memory.contains("DEVIATION"), "lines: \(memory.lines)")
    }

    func testAJumpThatWasNotSentYetIsNoDisagreementAboutThePosition() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        // The skip buttons were tapped again and again: the app shows the position it will jump to, and sends the jump when the taps stop.
        for _ in 0..<12 {
            now += 0.5
            shadow.compare(with: app(unsentJump: true, position: 400))
        }
        XCTAssertFalse(memory.contains("DEVIATION"), "lines: \(memory.lines)")
        // The same position with nothing waiting to be sent is a player somewhere else.
        for _ in 0..<10 {
            now += 0.5
            shadow.compare(with: app(position: 400))
        }
        XCTAssertTrue(memory.contains("DEVIATION position"), "lines: \(memory.lines)")
    }

    func testOnlyTheNewestInstructionsAreKept() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        for second in 0..<600 { shadow.seek(to: Double(second)) }
        XCTAssertEqual(shadow.instructions.count, 500)
        guard case .seek(_, _, let position) = shadow.instructions.last else { return XCTFail("the last instruction is a jump: \(String(describing: shadow.instructions.last))") }
        XCTAssertEqual(position, 599)
    }

    func testAnAttemptThatIsGivenUpPutsTheStateMachineBackWhereThePlayerIs() {
        let shadow = makeShadow()
        startedPlaying(shadow, at: 30)
        // The app began to get another stream (a new track, the way back from the background) and told the state machine the stream failed ...
        shadow.playerFailed("the stream is made again")
        XCTAssertEqual(shadow.state.phase, .failed("the stream is made again"))
        // ... and could not get it. The old stream plays on, the app is back to normal.
        shadow.attemptGivenUp(item: "film", at: 31, quality: "original", audio: 1, subtitle: nil)
        XCTAssertEqual(shadow.state.phase, .playing)
        for _ in 0..<12 {
            now += 0.5
            shadow.compare(with: app(position: 31))
        }
        XCTAssertFalse(memory.contains("DEVIATION"), "lines: \(memory.lines)")
    }

    func testAnAttemptIsOnlyGivenUpWhereTheStateMachineWasToldItFailed() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.attemptGivenUp(item: "film", at: 5, quality: "original", audio: 1, subtitle: nil)
        XCTAssertEqual(shadow.state.phase, .playing)
        XCTAssertFalse(memory.contains("attempt given up"), "nothing to put back: \(memory.lines)")
    }

    func testAnItemTheViewerStartsPlaysWhateverWasBefore() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.pause()
        shadow.begin(item: "next", startAt: 0, quality: nil, audio: nil, subtitle: nil, reason: "episode")
        XCTAssertTrue(shadow.state.wantsPlay)
        shadow.playerIsReady()
        XCTAssertEqual(shadow.state.phase, .playing)
    }

    func testTheStateMachineStuckInSeekingWhileTheAppPlaysIsADeviation() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.seek(to: 900)
        for _ in 0..<12 {
            now += 0.5
            shadow.compare(with: app(position: 900))
        }
        XCTAssertTrue(memory.contains("DEVIATION phase-stuck"), "lines: \(memory.lines)")
        XCTAssertTrue(memory.contains("the state machine has been seeking for"))
    }

    func testTheWaitForDataAfterAPlayIsNoDeviationAStallThatTheStateMachineDoesNotSeeIsNot() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        for _ in 0..<20 {
            now += 0.5
            shadow.compare(with: app(waiting: true))
        }
        XCTAssertFalse(memory.contains("DEVIATION"), "the app waits and the state machine plays: that is a start, not a stall")
        shadow.playerStalled()
        for _ in 0..<20 {
            now += 0.5
            // The stall is over for the app (not waiting any more) and nobody told the state machine.
            shadow.compare(with: app())
        }
        XCTAssertTrue(memory.contains("DEVIATION phase"), "lines: \(memory.lines)")
    }

    func testAReplacementTheAppForgotIsReportedAndLetGoOf() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.qualityChangeBegins(to: "4Mbps", reason: "two stalls")
        // The app ended the change in a way that told the shadow nothing (an error path nobody hooked).
        for _ in 0..<6 {
            now += 0.5
            shadow.compare(with: app(changingQuality: false))
        }
        XCTAssertTrue(memory.contains("DEVIATION swap"), "lines: \(memory.lines)")
        XCTAssertNil(shadow.state.swap, "left alone it would keep every later change from beginning")
    }

    func testTheWrongItemAndAWrongPositionAreDeviations() {
        let shadow = makeShadow()
        startedPlaying(shadow, at: 10)
        shadow.playerMoved(to: 10)
        for _ in 0..<12 {
            now += 0.5
            shadow.compare(with: app(position: 120, item: "other"))
        }
        XCTAssertTrue(memory.contains("DEVIATION item"), "lines: \(memory.lines)")
        XCTAssertTrue(memory.contains("DEVIATION position"), "lines: \(memory.lines)")
    }

    func testReconnectingAndFailingAreExpectedToShowAsTheStateMachineLosingThePlayer() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.playerFailed("-19602")
        XCTAssertEqual(shadow.state.phase, .failed("-19602"))
        for _ in 0..<20 {
            now += 0.5
            shadow.compare(with: app(reconnecting: true))
        }
        XCTAssertFalse(memory.contains("DEVIATION"), "lines: \(memory.lines)")
    }

    func testAFailureIsNamedByItsDomainAndCodeAndAQualityByItsCap() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.playerFailed(error: NSError(domain: "CoreMediaErrorDomain", code: -16170))
        XCTAssertEqual(shadow.state.phase, .failed("CoreMediaErrorDomain -16170"))
        XCTAssertEqual(PlaybackShadow.qualityName(capMbps: nil), "original")
        XCTAssertEqual(PlaybackShadow.qualityName(capMbps: 4), "4Mbps")
        XCTAssertEqual(PlaybackShadow.qualityName(capMbps: 2.5), "2.5Mbps")
    }

    func testNothingHappensAfterTheEnd() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.end()
        let lines = memory.lines.count
        shadow.play()
        shadow.playerMoved(to: 5)
        shadow.compare(with: app(wantsToPlay: false))
        shadow.begin(item: "x", startAt: 0, quality: nil, audio: nil, subtitle: nil, reason: "late")
        XCTAssertEqual(memory.lines.count, lines)
        XCTAssertEqual(shadow.state.phase, .stopped)
    }

    func testTheEndOfTheItemIsWrittenDownThoughTheModelHasNoEventForIt() {
        let shadow = makeShadow()
        startedPlaying(shadow)
        shadow.playerReachedTheEnd()
        XCTAssertTrue(memory.contains("has no event for that"))
        XCTAssertEqual(shadow.state.phase, .playing)
    }
}
