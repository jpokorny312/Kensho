import Foundation

/// Runs the reducer against a real engine. App and engine used to each do
/// their own thing; this is the one place both go through, so every state
/// change and every instruction to the engine has a single, ordered history.
@MainActor
public final class PlaybackCoordinator {
    public private(set) var state = PlaybackState()
    /// Called after every event that changed the state.
    public var onStateChange: ((PlaybackState) -> Void)?
    /// Called with every transition, for logging: the event, the resulting
    /// phase and the instructions it produced.
    public var onTransition: ((PlaybackEvent, PlaybackState, [PlaybackEffect]) -> Void)?

    private let engine: any PlaybackEngine
    private let policy: PlaybackPolicy
    private var queue: [PlaybackEvent] = []
    private var isProcessing = false

    public init(engine: any PlaybackEngine, policy: PlaybackPolicy = PlaybackPolicy()) {
        self.engine = engine
        self.policy = policy
        engine.onEvent = { [weak self] event in self?.send(event) }
    }

    public func send(_ event: PlaybackEvent) {
        queue.append(event)
        // An engine may answer an instruction synchronously, from inside
        // `perform`. Handling that reply right away would reduce against a
        // state the first event has not finished producing; queue it and
        // drain in order.
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            let before = state
            let result = PlaybackReducer.reduce(state, next, policy: policy)
            state = result.state
            onTransition?(next, state, result.effects)
            for effect in result.effects { engine.perform(effect) }
            if state != before { onStateChange?(state) }
        }
    }
}
