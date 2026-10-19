import Foundation

/// The thing that actually plays. The coordinator tells it what to do through
/// `perform`; it reports back through `onEvent`. Both sides speak the same
/// `PlaybackEvent`/`PlaybackEffect` vocabulary the reducer uses.
///
/// What the reducer counts on, and what an engine that breaks it costs:
///
/// - A session an engine starts (`load`, `commitSwap`) begins **paused** at its
///   position; the reducer's `play` is what sets it going. An engine that
///   starts on its own plays a second or two of the wrong place before the
///   jump to the start position lands. (An owner that must not wait for its item can take that on and ask for an engine that plays at once:
///   `AVPlayerEngine.Options.startsPlayingAtOnce`, the car's. What holds such an engine is the reducer's `pause`, which it also sends while the item
///   is still loading.)
/// - Every report carries the epoch of the session it is about. The reducer
///   drops what is about a session that is not (or no longer) the live one, so
///   an engine never has to hold a late report back - but it must not report a
///   session under another session's epoch.
/// - A replacement (`prepareSwap`) is a session of its own. The one that plays
///   is not touched while it is made: it keeps reporting under its epoch, and
///   the replacement reports `swapPrepared` / `swapFailed` under its own. Only
///   `commitSwap` ends the old one.
/// - Every instruction ends in a report or is superseded by a newer one. A
///   seek that neither lands nor fails leaves the reducer in `.seeking` for
///   good; a `commitSwap` for a session the engine no longer has is a failure
///   to report, not something to ignore.
@MainActor
public protocol PlaybackEngine: AnyObject {
    /// Set by the coordinator. The engine calls it, on the main actor, for
    /// everything it observes (ready, stall, tick, seek finished, failure).
    var onEvent: ((PlaybackEvent) -> Void)? { get set }

    /// Starts working on one instruction. Must not block: long operations
    /// (loading, seeking) report completion later through `onEvent`.
    func perform(_ effect: PlaybackEffect)
}
