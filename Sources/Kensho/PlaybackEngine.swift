import Foundation

/// The thing that actually plays. The coordinator tells it what to do through
/// `perform`; it reports back through `onEvent`. Both sides speak the same
/// `PlaybackEvent`/`PlaybackEffect` vocabulary the reducer uses.
@MainActor
public protocol PlaybackEngine: AnyObject {
    /// Set by the coordinator. The engine calls it, on the main actor, for
    /// everything it observes (ready, stall, tick, seek finished, failure).
    var onEvent: ((PlaybackEvent) -> Void)? { get set }

    /// Starts working on one instruction. Must not block: long operations
    /// (loading, seeking) report completion later through `onEvent`.
    func perform(_ effect: PlaybackEffect)
}
