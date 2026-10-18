import AVFoundation
import Kensho

/// Tells a stall from a start in what `AVPlayer.timeControlStatus` says.
///
/// AVPlayer shows `waitingToPlayAtSpecifiedRate` for every play(): the wait for
/// the first data looks exactly like starvation in the middle of a film. An
/// engine that reported each as a stall made the quality policy step down for
/// nothing (Enso's `BufferingStallDetector` has a grace period for this; the
/// player was measured to report it 2026-10-18, see `AVPlayerEngineTests`).
///
/// A stall is playback that was running and ran dry: the status goes from
/// `playing` to waiting, and not because the engine itself moved the playhead.
/// Waiting that follows `paused` is a start, a stall only if it lasts
/// (`resumeGrace`, the same three seconds as in Enso's detector: a start that
/// never gets going is as much a thing to act on as one that broke off).
/// Waiting during a seek is the seek.
struct StallWatch {
    enum Report: Equatable {
        case stalled
        case recovered
    }

    /// How long a wait that began at a start may last before it counts as a stall.
    static let resumeGrace: TimeInterval = 3

    private var previous: AVPlayer.TimeControlStatus = .paused
    /// When the wait of a start began, while it goes on.
    private var startWaitBegan: TimeInterval?

    /// - Parameters:
    ///   - seekInFlight: a seek the engine started has not landed yet.
    ///   - now: seconds on any steady scale (only differences count).
    mutating func observe(_ status: AVPlayer.TimeControlStatus, seekInFlight: Bool, now: TimeInterval) -> Report? {
        defer { previous = status }
        switch status {
        case .playing:
            startWaitBegan = nil
            return .recovered
        case .waitingToPlayAtSpecifiedRate:
            if previous == .playing && !seekInFlight {
                startWaitBegan = nil
                return .stalled
            }
            // A wait that begins after a pause is a start; one that goes on from a wait already counted keeps its beginning.
            if previous == .paused && !seekInFlight { startWaitBegan = now }
            return nil
        case .paused:
            startWaitBegan = nil
            return nil
        @unknown default:
            return nil
        }
    }

    /// Asked a grace period after a wait began: a start that is still waiting is a stall now.
    mutating func graceIsOver(now: TimeInterval) -> Report? {
        guard let began = startWaitBegan, previous == .waitingToPlayAtSpecifiedRate, now - began >= Self.resumeGrace else { return nil }
        startWaitBegan = nil
        return .stalled
    }
}
