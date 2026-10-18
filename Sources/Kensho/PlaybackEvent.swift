import Foundation

/// Everything that can happen to a playback. UI intents and engine reports
/// share one type so the reducer sees a single ordered stream.
public enum PlaybackEvent: Equatable, Sendable {
    // Viewer intents.
    case load(MediaSource, startAt: TimeInterval, selection: TrackSelection, quality: QualityChoice?)
    /// The app makes the stream of what it is playing again, under the viewer: after a failure (a reconnect, a fallback), for a track the stream
    /// cannot switch live, for a source it re-reads. A new session of the same source, at `startAt`; what the viewer wants stays what it was - a `load`
    /// is the viewer starting something and wants playback, a reload must not undo a pause.
    case reload(startAt: TimeInterval, selection: TrackSelection, quality: QualityChoice?)
    case play
    case pause
    case seek(to: TimeInterval)
    case selectAudio(Int?)
    case selectSubtitle(Int?)
    case requestQuality(QualityChoice, now: TimeInterval)
    case stop

    // Engine reports. Each carries the epoch it was issued for.
    case engineReady(Epoch)
    case engineFailed(Epoch, reason: String)
    case engineStalled(Epoch)
    case engineRecovered(Epoch)
    case engineTick(Epoch, position: TimeInterval)
    case seekFinished(Epoch, SeekToken)
    /// A replacement session (`prepareSwap`) is ready to take over.
    case swapPrepared(Epoch)
    /// A replacement session could not be made. The running one goes on.
    case swapFailed(Epoch, reason: String)
    /// The replacement that took over (`commitSwap`) is at its position and can play.
    case swapFinished(Epoch)
}

/// What the host must do in response. The reducer never touches an engine;
/// it only describes the next step, which keeps it testable.
///
/// An engine starts every session it is asked for - a `load`, a `commitSwap` -
/// paused at its position; the reducer's `play` is what sets it going.
public enum PlaybackEffect: Equatable, Sendable {
    case load(Epoch, MediaSource, startAt: TimeInterval, selection: TrackSelection, quality: QualityChoice?)
    case play(Epoch)
    case pause(Epoch)
    case seek(Epoch, SeekToken, to: TimeInterval)
    case applySelection(Epoch, TrackSelection)
    /// Get a replacement session ready WHILE the running one plays on. `startAt` is where the running one was when it was asked for; the
    /// replacement is told where to begin by `commitSwap`, when it takes over.
    case prepareSwap(Epoch, QualityChoice, startAt: TimeInterval, selection: TrackSelection)
    /// The prepared session (`Epoch`) takes over from the running one (`replacing`), beginning at `at` - the position NOW, not the one at the
    /// request - with `selection` applied. The old session ends.
    case commitSwap(Epoch, replacing: Epoch, at: TimeInterval, selection: TrackSelection)
    /// A replacement that is not wanted any more (the viewer loaded something else, or stopped) is thrown away.
    case discardSwap(Epoch)
    case stop(Epoch)
}
