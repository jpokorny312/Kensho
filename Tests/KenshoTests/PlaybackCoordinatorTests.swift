import XCTest
@testable import Kensho

/// An engine that writes down what it is asked and answers the way a test says.
@MainActor
final class FakeEngine: PlaybackEngine {
    var onEvent: ((PlaybackEvent) -> Void)?
    private(set) var performed: [PlaybackEffect] = []
    /// What the engine reports from inside `perform`, per effect (an engine that is ready at once).
    var reply: ((PlaybackEffect) -> [PlaybackEvent])?

    func perform(_ effect: PlaybackEffect) {
        performed.append(effect)
        for event in reply?(effect) ?? [] { onEvent?(event) }
    }
}

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .dolbyVision)
    private let sdrFilm = MediaSource(id: "film", range: .sdr)
    private let hi = QualityChoice(id: "hi", range: .sdr)
    private let lo = QualityChoice(id: "lo", range: .sdr)

    private func make(clock: @escaping () -> TimeInterval = { 0 }) -> (PlaybackCoordinator, FakeEngine) {
        let engine = FakeEngine()
        return (PlaybackCoordinator(engine: engine, clock: clock), engine)
    }

    func testEffectsReachTheEngineInOrder() {
        let (coordinator, engine) = make()
        coordinator.send(.load(film, startAt: 10, selection: TrackSelection(), quality: hi))
        XCTAssertEqual(engine.performed, [.load(Epoch(1), film, startAt: 10, selection: TrackSelection(), quality: hi)])
        XCTAssertEqual(coordinator.state.phase, .loading)
        engine.onEvent?(.engineReady(Epoch(1)))
        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertEqual(engine.performed.last, .play(Epoch(1)))
    }

    func testSynchronousEngineReplyIsQueuedNotReentered() {
        let (coordinator, engine) = make()
        engine.reply = { effect in
            if case let .load(epoch, _, _, _, _) = effect { return [.engineReady(epoch)] }
            return []
        }
        coordinator.load(film)
        XCTAssertEqual(coordinator.state.phase, .playing)
        // The report arrived while `load` was being handed over: it was handled after, and `play` came after `load`.
        XCTAssertEqual(engine.performed, [.load(Epoch(1), film, startAt: 0, selection: TrackSelection(), quality: nil), .play(Epoch(1))])
    }

    func testStateChangeCallbackFiresOnlyOnChange() {
        let (coordinator, engine) = make()
        var announced: [Phase] = []
        coordinator.onStateChange = { announced.append($0.phase) }
        coordinator.load(film)
        engine.onEvent?(.engineReady(Epoch(1)))
        engine.onEvent?(.engineReady(Epoch(1)))           // a second report of the same: nothing changes
        engine.onEvent?(.engineTick(Epoch(9), position: 5)) // a session that is not the live one: nothing changes
        XCTAssertEqual(announced, [.loading, .playing])
    }

    func testTransitionHookSeesEveryEventEvenOneThatChangedNothing() {
        let (coordinator, engine) = make()
        var seen: [PlaybackEvent] = []
        var effectCounts: [Int] = []
        coordinator.onTransition = { event, _, effects in
            seen.append(event)
            effectCounts.append(effects.count)
        }
        coordinator.load(film)
        engine.onEvent?(.engineReady(Epoch(99)))  // stale: dropped, but it is in the log
        coordinator.pause()
        XCTAssertEqual(seen, [
            .load(film, startAt: 0, selection: TrackSelection(), quality: nil),
            .engineReady(Epoch(99)),
            .pause,
        ])
        XCTAssertEqual(effectCounts, [1, 0, 1], "load asked the engine for one thing, the stale report for nothing, the pause during loading for one (an engine that plays at once is held)")
    }

    func testTheTransitionHookRunsBeforeTheEngineGetsTheEffects() {
        let (coordinator, engine) = make()
        var performedWhenLogged: [Int] = []
        coordinator.onTransition = { _, _, _ in performedWhenLogged.append(engine.performed.count) }
        coordinator.load(film)
        XCTAssertEqual(performedWhenLogged, [0], "the decision is written down before it is carried out, so a crash in the engine still leaves it in the log")
        XCTAssertEqual(engine.performed.count, 1)
    }

    func testTheViewersIntentsAreEventsInOrder() {
        let (coordinator, engine) = make()
        coordinator.load(film)
        engine.onEvent?(.engineReady(Epoch(1)))
        coordinator.pause()
        coordinator.seek(to: 60)
        coordinator.play()
        XCTAssertEqual(coordinator.state.phase, .seeking)
        XCTAssertEqual(coordinator.state.position, 60)
        guard case let .seek(_, token, to: target)? = engine.performed.last else { return XCTFail("the engine was asked to seek: \(engine.performed)") }
        XCTAssertEqual(target, 60)
        engine.onEvent?(.seekFinished(Epoch(1), token))
        XCTAssertEqual(coordinator.state.phase, .playing, "play after the pause: it plays on once the jump has landed")
        XCTAssertEqual(engine.performed.last, .play(Epoch(1)))
    }

    func testTheQualityCooldownRunsOnTheCoordinatorsClock() {
        var now = 100.0
        let (coordinator, engine) = make(clock: { now })
        coordinator.load(sdrFilm, quality: hi)
        engine.onEvent?(.engineReady(Epoch(1)))
        coordinator.requestQuality(lo)
        engine.onEvent?(.swapPrepared(Epoch(2)))
        engine.onEvent?(.swapFinished(Epoch(2)))
        now = 110
        coordinator.requestQuality(hi)
        XCTAssertNil(coordinator.state.swap, "ten seconds after the last change: too soon")
        now = 140
        coordinator.requestQuality(hi)
        XCTAssertNotNil(coordinator.state.swap, "forty seconds after: a replacement is prepared")
    }

    func testAReplacementIsMadeAndTakesOverWithTheEnginesHelp() {
        let (coordinator, engine) = make()
        coordinator.load(sdrFilm, quality: hi)
        engine.onEvent?(.engineReady(Epoch(1)))
        engine.onEvent?(.engineTick(Epoch(1), position: 33))
        coordinator.requestQuality(lo)
        XCTAssertEqual(engine.performed.last, .prepareSwap(Epoch(2), lo, startAt: 33, selection: TrackSelection()))
        engine.onEvent?(.engineTick(Epoch(1), position: 40))
        engine.onEvent?(.swapPrepared(Epoch(2)))
        XCTAssertEqual(engine.performed.last, .commitSwap(Epoch(2), replacing: Epoch(1), at: 40, selection: TrackSelection()))
        engine.onEvent?(.swapFinished(Epoch(2)))
        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertEqual(coordinator.state.quality, lo)
        XCTAssertEqual(engine.performed.last, .play(Epoch(2)))
    }

    func testAReloadReachesTheEngineAsAFreshSessionAndKeepsThePause() {
        let (coordinator, engine) = make()
        coordinator.load(film)
        engine.onEvent?(.engineReady(Epoch(1)))
        coordinator.pause()
        coordinator.reload(startAt: 42, quality: lo)
        XCTAssertEqual(engine.performed.last, .load(Epoch(2), film, startAt: 42, selection: TrackSelection(), quality: lo))
        engine.onEvent?(.engineReady(Epoch(2)))
        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertEqual(engine.performed.last, .load(Epoch(2), film, startAt: 42, selection: TrackSelection(), quality: lo), "nothing set it going")
    }

    func testTheCoordinatorDoesNotKeepItsEngineFromGoingAway() {
        weak var weakCoordinator: PlaybackCoordinator?
        let engine = FakeEngine()
        do {
            let coordinator = PlaybackCoordinator(engine: engine)
            weakCoordinator = coordinator
        }
        XCTAssertNil(weakCoordinator, "the engine's report closure holds the coordinator weakly")
    }
}
