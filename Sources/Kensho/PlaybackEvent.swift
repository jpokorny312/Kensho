import Foundation

/// Everything that can happen to a playback. UI intents and engine reports
/// share one type so the reducer sees a single ordered stream.
public enum PlaybackEvent: Equatable, Sendable {
    // Viewer intents.
    case load(MediaSource, startAt: TimeInterval, selection: TrackSelection, quality: QualityChoice?)
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
    case swapFinished(Epoch)
}

/// What the host must do in response. The reducer never touches an engine;
/// it only describes the next step, which keeps it testable.
public enum PlaybackEffect: Equatable, Sendable {
    case load(Epoch, MediaSource, startAt: TimeInterval, selection: TrackSelection, quality: QualityChoice?)
    case play(Epoch)
    case pause(Epoch)
    case seek(Epoch, SeekToken, to: TimeInterval)
    case applySelection(Epoch, TrackSelection)
    /// Replace the running session, resuming at `startAt`. Position is carried
    /// over so a quality change is not a restart.
    case swap(Epoch, QualityChoice, startAt: TimeInterval, selection: TrackSelection)
    case stop(Epoch)
}
