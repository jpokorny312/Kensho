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
/// Waiting that follows `paused` is a start; waiting during a seek is the seek.
struct StallWatch {
    enum Report: Equatable {
        case stalled
        case recovered
    }

    private var previous: AVPlayer.TimeControlStatus = .paused

    /// - Parameter seekInFlight: a seek the engine started has not landed yet.
    mutating func observe(_ status: AVPlayer.TimeControlStatus, seekInFlight: Bool) -> Report? {
        defer { previous = status }
        switch status {
        case .playing:
            return .recovered
        case .waitingToPlayAtSpecifiedRate:
            return previous == .playing && !seekInFlight ? .stalled : nil
        case .paused:
            return nil
        @unknown default:
            return nil
        }
    }
}
