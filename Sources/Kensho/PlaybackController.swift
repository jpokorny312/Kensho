import Foundation

/// What carries out the reducer's effects: an AVPlayer in an app, a fake in a test.
///
/// An engine starts every session it is asked for (`load`, `commitSwap`) paused at its position; the reducer's `play` is what sets it going. It reports
/// what happens to its sessions through `report`, each report carrying the epoch of the session it is about - the reducer drops what is about a session
/// that is not (or no longer) the live one.
@MainActor
public protocol PlaybackEngine: AnyObject {
    /// Set by the controller.
    var report: (@MainActor (PlaybackEvent) -> Void)? { get set }
    func execute(_ effect: PlaybackEffect)
}

/// The reducer, an engine and the state between them: events go in one at a time, in the order they came, and what the reducer asks for is handed to
/// the engine in the order it asked.
///
/// An engine that reports from inside `execute` (a fake that is ready at once) does not reorder anything: its report waits until the event that is
/// being handled is done, so effects always reach the engine in the order of the events that caused them.
@MainActor
public final class PlaybackController {
    public private(set) var state = PlaybackState()
    public var policy: PlaybackPolicy
    /// Called after every event that changed the state.
    public var onChange: (@MainActor (PlaybackState) -> Void)?

    private let engine: any PlaybackEngine
    private let clock: () -> TimeInterval
    private var queue: [PlaybackEvent] = []
    private var isHandling = false

    /// - Parameter clock: seconds on any steady scale; only differences matter (the cooldown between two quality changes).
    public init(engine: any PlaybackEngine, policy: PlaybackPolicy = PlaybackPolicy(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = engine
        self.policy = policy
        self.clock = clock
        engine.report = { [weak self] event in self?.send(event) }
    }

    public func send(_ event: PlaybackEvent) {
        queue.append(event)
        guard !isHandling else { return }
        isHandling = true
        defer { isHandling = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            let result = PlaybackReducer.reduce(state, next, policy: policy)
            let changed = result.state != state
            state = result.state
            if changed { onChange?(state) }
            for effect in result.effects { engine.execute(effect) }
        }
    }

    // MARK: - What the viewer does

    public func load(_ source: MediaSource, startAt: TimeInterval = 0, selection: TrackSelection = TrackSelection(), quality: QualityChoice? = nil) {
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
