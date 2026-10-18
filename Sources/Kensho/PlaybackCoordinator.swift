import Foundation

/// Runs the reducer against a real engine. App and engine used to each do
/// their own thing; this is the one place both go through, so every state
/// change and every instruction to the engine has a single, ordered history.
///
/// Events go in one at a time, in the order they came, and what the reducer
/// asks for is handed to the engine in the order it asked.
@MainActor
public final class PlaybackCoordinator {
    public private(set) var state = PlaybackState()
    public var policy: PlaybackPolicy
    /// Called after every event that changed the state.
    public var onStateChange: ((PlaybackState) -> Void)?
    /// Called with every transition, for logging: the event, the resulting
    /// state and the instructions it produced - before the engine gets them.
    /// Also called for an event that changed nothing (a stale report), which
    /// is exactly what a log that looks for lost state wants to see.
    public var onTransition: ((PlaybackEvent, PlaybackState, [PlaybackEffect]) -> Void)?

    private let engine: any PlaybackEngine
    private let clock: () -> TimeInterval
    private var queue: [PlaybackEvent] = []
    private var isProcessing = false

    /// - Parameter clock: seconds on any steady scale; only differences matter
    ///   (the cooldown between two quality changes). The reducer takes the time
    ///   as a parameter so it stays pure; this is the one place that reads it.
    public init(
        engine: any PlaybackEngine,
        policy: PlaybackPolicy = PlaybackPolicy(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.engine = engine
        self.policy = policy
        self.clock = clock
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

    // MARK: - What the viewer does

    public func load(
        _ source: MediaSource,
        startAt: TimeInterval = 0,
        selection: TrackSelection = TrackSelection(),
        quality: QualityChoice? = nil
    ) {
        send(.load(source, startAt: startAt, selection: selection, quality: quality))
    }
    public func play() { send(.play) }
    public func pause() { send(.pause) }
    public func seek(to position: TimeInterval) { send(.seek(to: position)) }
    public func selectAudio(_ track: Int?) { send(.selectAudio(track)) }
    public func selectSubtitle(_ track: Int?) { send(.selectSubtitle(track)) }
    public func requestQuality(_ choice: QualityChoice) { send(.requestQuality(choice, now: clock())) }
    public func stop() { send(.stop) }
}
