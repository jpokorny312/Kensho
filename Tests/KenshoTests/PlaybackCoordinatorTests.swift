import XCTest
@testable import Kensho

@MainActor
private final class FakeEngine: PlaybackEngine {
    var onEvent: ((PlaybackEvent) -> Void)?
    var performed: [PlaybackEffect] = []
    /// Replies the engine gives synchronously, from inside `perform`.
    var reply: ((PlaybackEffect) -> [PlaybackEvent])?

    func perform(_ effect: PlaybackEffect) {
        performed.append(effect)
        for event in reply?(effect) ?? [] { onEvent?(event) }
    }
}

final class PlaybackCoordinatorTests: XCTestCase {
    private let source = MediaSource(id: "film", range: .dolbyVision)

    @MainActor func testEffectsReachTheEngineInOrder() async {
        let engine = FakeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.send(.load(source, startAt: 0, selection: TrackSelection(), quality: nil))
        coordinator.send(.engineReady(Epoch(1)))
        XCTAssertEqual(engine.performed.count, 2)
        XCTAssertEqual(engine.performed.last, .play(Epoch(1)))
        XCTAssertEqual(coordinator.state.phase, .playing)
    }

    @MainActor func testSynchronousEngineReplyIsQueuedNotReentered() async {
        let engine = FakeEngine()
        engine.reply = { effect in
            if case let .load(epoch, _, _, _, _) = effect { return [.engineReady(epoch)] }
            return []
        }
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.send(.load(source, startAt: 0, selection: TrackSelection(), quality: nil))
        XCTAssertEqual(coordinator.state.phase, .playing)
        // load first, then the play that the queued reply produced.
        XCTAssertEqual(engine.performed.count, 2)
        if case .load = engine.performed[0] {} else { XCTFail("load must come first") }
        XCTAssertEqual(engine.performed[1], .play(Epoch(1)))
    }

    @MainActor func testStateChangeCallbackFiresOnlyOnChange() async {
        let engine = FakeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var changes = 0
        coordinator.onStateChange = { _ in changes += 1 }
        coordinator.send(.load(source, startAt: 0, selection: TrackSelection(), quality: nil))
        let afterLoad = changes
        coordinator.send(.engineReady(Epoch(99)))  // stale epoch: no change
        XCTAssertEqual(changes, afterLoad)
    }

    @MainActor func testTransitionHookSeesEveryEvent() async {
        let engine = FakeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var seen: [PlaybackEvent] = []
        coordinator.onTransition = { event, _, _ in seen.append(event) }
        coordinator.send(.load(source, startAt: 0, selection: TrackSelection(), quality: nil))
        coordinator.send(.pause)
        XCTAssertEqual(seen.count, 2)
    }
}
