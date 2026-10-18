import XCTest
@testable import Kensho

/// An engine that writes down what it is asked and answers the way a test says.
@MainActor
final class FakeEngine: PlaybackEngine {
    var report: (@MainActor (PlaybackEvent) -> Void)?
    private(set) var effects: [PlaybackEffect] = []
    /// What the engine reports from inside `execute`, per effect (an engine that is ready at once).
    var answers: (PlaybackEffect) -> [PlaybackEvent] = { _ in [] }

    func execute(_ effect: PlaybackEffect) {
        effects.append(effect)
        for event in answers(effect) { report?(event) }
    }
}

@MainActor
final class PlaybackControllerTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .sdr)
    private let hi = QualityChoice(id: "hi", range: .sdr)
    private let lo = QualityChoice(id: "lo", range: .sdr)

    private func make(clock: @escaping () -> TimeInterval = { 0 }) -> (PlaybackController, FakeEngine) {
        let engine = FakeEngine()
        return (PlaybackController(engine: engine, clock: clock), engine)
    }

    func testTheEnginesReportsReachTheReducerAndItsEffectsReachTheEngine() {
        let (controller, engine) = make()
        controller.load(film, startAt: 10, quality: hi)
        XCTAssertEqual(engine.effects, [.load(Epoch(1), film, startAt: 10, selection: TrackSelection(), quality: hi)])
        XCTAssertEqual(controller.state.phase, .loading)
        engine.report?(.engineReady(Epoch(1)))
        XCTAssertEqual(controller.state.phase, .playing)
        XCTAssertEqual(engine.effects.last, .play(Epoch(1)))
    }

    func testAnEngineThatIsReadyAtOnceDoesNotReorderTheEffects() {
        let (controller, engine) = make()
        engine.answers = { effect in
            if case let .load(epoch, _, _, _, _) = effect { return [.engineReady(epoch)] }
            return []
        }
        controller.load(film)
        // The report arrived while `load` was being handed over: it was handled after, and `play` came after `load`.
        XCTAssertEqual(engine.effects, [.load(Epoch(1), film, startAt: 0, selection: TrackSelection(), quality: nil), .play(Epoch(1))])
        XCTAssertEqual(controller.state.phase, .playing)
    }

    func testOnlyChangesAreAnnounced() {
        let (controller, engine) = make()
        var announced: [Phase] = []
        controller.onChange = { announced.append($0.phase) }
        controller.load(film)
        engine.report?(.engineReady(Epoch(1)))
        engine.report?(.engineReady(Epoch(1)))          // a second report of the same: nothing changes
        engine.report?(.engineTick(Epoch(9), position: 5)) // a session that is not the live one: nothing changes
        XCTAssertEqual(announced, [.loading, .playing])
    }

    func testTheViewersIntentsAreEventsInOrder() {
        let (controller, engine) = make()
        controller.load(film)
        engine.report?(.engineReady(Epoch(1)))
        controller.pause()
        controller.seek(to: 60)
        controller.play()
        XCTAssertEqual(controller.state.phase, .seeking)
        XCTAssertEqual(controller.state.position, 60)
        guard case let .seek(_, token, to: target)? = engine.effects.last else { return XCTFail("the engine was asked to seek: \(engine.effects)") }
        XCTAssertEqual(target, 60)
        engine.report?(.seekFinished(Epoch(1), token))
        XCTAssertEqual(controller.state.phase, .playing, "play after the pause: it plays on once the jump has landed")
        XCTAssertEqual(engine.effects.last, .play(Epoch(1)))
    }

    func testTheQualityCooldownRunsOnTheControllersClock() {
        var now = 100.0
        let (controller, engine) = make(clock: { now })
        controller.load(film, quality: hi)
        engine.report?(.engineReady(Epoch(1)))
        controller.requestQuality(lo)
        engine.report?(.swapPrepared(Epoch(2)))
        engine.report?(.swapFinished(Epoch(2)))
        now = 110
        controller.requestQuality(hi)
        XCTAssertNil(controller.state.swap, "ten seconds after the last change: too soon")
        now = 140
        controller.requestQuality(hi)
        XCTAssertNotNil(controller.state.swap, "forty seconds after: a replacement is prepared")
    }

    func testAReplacementIsMadeAndTakesOverWithTheEnginesHelp() {
        let (controller, engine) = make()
        controller.load(film, quality: hi)
        engine.report?(.engineReady(Epoch(1)))
        engine.report?(.engineTick(Epoch(1), position: 33))
        controller.requestQuality(lo)
        XCTAssertEqual(engine.effects.last, .prepareSwap(Epoch(2), lo, startAt: 33, selection: TrackSelection()))
        engine.report?(.engineTick(Epoch(1), position: 40))
        engine.report?(.swapPrepared(Epoch(2)))
        XCTAssertEqual(engine.effects.last, .commitSwap(Epoch(2), replacing: Epoch(1), at: 40, selection: TrackSelection()))
        engine.report?(.swapFinished(Epoch(2)))
        XCTAssertEqual(controller.state.phase, .playing)
        XCTAssertEqual(controller.state.quality, lo)
        XCTAssertEqual(engine.effects.last, .play(Epoch(2)))
    }

    func testTheControllerDoesNotKeepItsEngineFromGoingAway() {
        weak var weakController: PlaybackController?
        let engine = FakeEngine()
        autoreleasepool {
            let controller = PlaybackController(engine: engine)
            weakController = controller
        }
        XCTAssertNil(weakController, "the engine's report closure holds the controller weakly")
    }
}
