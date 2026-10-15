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

    private func playing() -> PlaybackState {
        let (s, _) = run([
            .load(source, startAt: 0, selection: TrackSelection(audio: 1), quality: hi),
            .engineReady(Epoch(1)),
        ])
        return s
    }

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
        XCTAssertFalse(fx.contains(where: { if case .applySelection = $0 { return true } else { return false } }))
        let token = s.seekToken
        (s, fx) = run([.seekFinished(Epoch(1), token)], from: s)
        XCTAssertEqual(fx.first, .applySelection(Epoch(1), TrackSelection(audio: 2)))
        XCTAssertEqual(fx.last, .play(Epoch(1)))
    }

    func testTrackChangeWhenSteadyAppliesImmediately() {
        let (_, fx) = run([.selectSubtitle(3)], from: playing())
        XCTAssertEqual(fx, [.applySelection(Epoch(1), TrackSelection(audio: 1, subtitle: 3))])
    }

    func testQualitySwapCarriesPositionAndNewEpoch() {
        let (s, fx) = run([.engineTick(Epoch(1), position: 42), .requestQuality(lo, now: 100)], from: playing())
        XCTAssertEqual(s.phase, .switching)
        XCTAssertEqual(s.epoch, Epoch(2))
        XCTAssertEqual(fx.last, .swap(Epoch(2), lo, startAt: 42, selection: TrackSelection(audio: 1)))
    }

    func testQualityCooldownBlocksFlapping() {
        var (s, _) = run([.requestQuality(lo, now: 100), .swapFinished(Epoch(2))], from: playing())
        let (_, fx) = run([.requestQuality(hi, now: 110)], from: s)
        XCTAssertTrue(fx.isEmpty)
        (s, _) = run([.requestQuality(hi, now: 131)], from: s)
        XCTAssertEqual(s.phase, .switching)
    }

    func testQualityChangeAcrossVideoRangeIsRefused() {
        let (s, fx) = run([.requestQuality(sdr, now: 100)], from: playing())
        XCTAssertEqual(s.phase, .playing)
        XCTAssertTrue(fx.isEmpty)
    }

    func testQualityIsRefusedWhileSeeking() {
        let (s, fx) = run([.seek(to: 10), .requestQuality(lo, now: 100)], from: playing())
        XCTAssertEqual(s.phase, .seeking)
        XCTAssertFalse(fx.contains(where: { if case .swap = $0 { return true } else { return false } }))
    }

    func testSeekDuringSwapIsAppliedAfterSwap() {
        let (s, fx) = run([
            .requestQuality(lo, now: 100),
            .seek(to: 500),
            .swapFinished(Epoch(2)),
        ], from: playing())
        XCTAssertEqual(s.phase, .seeking)
        XCTAssertEqual(fx.last, .seek(Epoch(2), s.seekToken, to: 500))
    }

    func testLateEventsFromOldEpochAfterSwapAreDropped() {
        let (s, _) = run([
            .requestQuality(lo, now: 100),
            .engineFailed(Epoch(1), reason: "old session torn down"),
            .engineStalled(Epoch(1)),
        ], from: playing())
        XCTAssertEqual(s.phase, .switching)
    }

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
}
