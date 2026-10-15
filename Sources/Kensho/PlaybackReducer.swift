import Foundation

public struct PlaybackPolicy: Sendable {
    /// Minimum time between two quality swaps. Every swap is a new engine
    /// session (a visible stall), so letting the ladder flap is worse than
    /// staying one rung too low for a while.
    public var qualityCooldown: TimeInterval
    public init(qualityCooldown: TimeInterval = 30) {
        self.qualityCooldown = qualityCooldown
    }
}

/// The single place that decides what playback does next. Pure on purpose:
/// no engine, no clock, no threads — events in, state and effects out.
public enum PlaybackReducer {
    public static func reduce(
        _ state: PlaybackState,
        _ event: PlaybackEvent,
        policy: PlaybackPolicy = PlaybackPolicy()
    ) -> (state: PlaybackState, effects: [PlaybackEffect]) {
        var s = state
        var fx: [PlaybackEffect] = []

        switch event {

        case let .load(source, startAt, selection, quality):
            s.epoch = s.epoch.next()
            s.phase = .loading
            s.wantsPlay = true
            s.source = source
            s.quality = quality
            s.selection = selection
            s.position = max(0, startAt)
            s.pendingSeek = nil
            s.pendingSelection = nil
            fx.append(.load(s.epoch, source, startAt: s.position, selection: selection, quality: quality))

        case .play:
            guard isLive(s) else { break }
            s.wantsPlay = true
            if s.phase == .paused {
                s.phase = .playing
                fx.append(.play(s.epoch))
            }

        case .pause:
            guard isLive(s) else { break }
            s.wantsPlay = false
            switch s.phase {
            case .playing, .buffering:
                s.phase = .paused
                fx.append(.pause(s.epoch))
            case .seeking:
                // The engine may auto-resume after the jump; make it hold.
                fx.append(.pause(s.epoch))
            default:
                break
            }

        case let .seek(target):
            guard isLive(s) else { break }
            let t = max(0, target)
            s.position = t
            switch s.phase {
            case .loading, .switching:
                s.pendingSeek = t
            default:
                s.seekToken = s.seekToken.next()
                s.phase = .seeking
                fx.append(.seek(s.epoch, s.seekToken, to: t))
            }

        case let .selectAudio(track):
            var sel = s.selection
            sel.audio = track
            select(sel, &s, &fx)

        case let .selectSubtitle(track):
            var sel = s.selection
            sel.subtitle = track
            select(sel, &s, &fx)

        case let .requestQuality(choice, now):
            guard s.isSteady, choice != s.quality else { break }
            // AVPlayer cannot move between SDR, HDR10 and Dolby Vision inside
            // one item, and a range change is a visible display-mode switch.
            if let current = s.quality?.range ?? s.source?.range, current != choice.range { break }
            if let last = s.lastQualityChange, now - last < policy.qualityCooldown { break }
            s.epoch = s.epoch.next()
            s.phase = .switching
            s.quality = choice
            s.lastQualityChange = now
            s.pendingSelection = nil
            fx.append(.swap(s.epoch, choice, startAt: s.position, selection: s.selection))

        case .stop:
            guard s.phase != .idle, s.phase != .stopped else { break }
            let old = s.epoch
            s.epoch = s.epoch.next()
            s.phase = .stopped
            s.wantsPlay = false
            s.pendingSeek = nil
            s.pendingSelection = nil
            fx.append(.stop(old))

        case let .engineReady(e):
            guard e == s.epoch, s.phase == .loading else { break }
            settle(&s, &fx)

        case let .swapFinished(e):
            guard e == s.epoch, s.phase == .switching else { break }
            settle(&s, &fx)

        case let .seekFinished(e, token):
            guard e == s.epoch, s.phase == .seeking, token == s.seekToken else { break }
            s.phase = s.wantsPlay ? .playing : .paused
            flushSelection(&s, &fx)
            if s.wantsPlay { fx.append(.play(s.epoch)) }

        case let .engineStalled(e):
            guard e == s.epoch, s.phase == .playing else { break }
            s.phase = .buffering

        case let .engineRecovered(e):
            guard e == s.epoch, s.phase == .buffering else { break }
            s.phase = .playing

        case let .engineTick(e, position):
            // Ticks during a seek or load still describe the old position and
            // would drag the UI back from the target.
            guard e == s.epoch, s.isSteady else { break }
            s.position = position

        case let .engineFailed(e, reason):
            guard e == s.epoch, isLive(s) else { break }
            s.phase = .failed(reason)
        }

        return (s, fx)
    }

    // A playback accepts intents once it has been loaded and until it ends.
    private static func isLive(_ s: PlaybackState) -> Bool {
        switch s.phase {
        case .idle, .stopped, .failed: return false
        default: return true
        }
    }

    /// A fresh session is up: honour a seek made while it was loading,
    /// otherwise start (or hold) according to what the viewer wants.
    private static func settle(_ s: inout PlaybackState, _ fx: inout [PlaybackEffect]) {
        if let target = s.pendingSeek {
            s.pendingSeek = nil
            s.seekToken = s.seekToken.next()
            s.phase = .seeking
            fx.append(.seek(s.epoch, s.seekToken, to: target))
            return
        }
        s.phase = s.wantsPlay ? .playing : .paused
        flushSelection(&s, &fx)
        if s.wantsPlay { fx.append(.play(s.epoch)) }
    }

    private static func select(_ sel: TrackSelection, _ s: inout PlaybackState, _ fx: inout [PlaybackEffect]) {
        guard isLive(s), sel != s.selection else { return }
        s.selection = sel
        if s.isSteady {
            fx.append(.applySelection(s.epoch, sel))
        } else {
            // Mid-seek or mid-swap the engine would apply it to a session
            // about to be replaced, or race the jump. Hold until steady.
            s.pendingSelection = sel
        }
    }

    private static func flushSelection(_ s: inout PlaybackState, _ fx: inout [PlaybackEffect]) {
        guard let sel = s.pendingSelection else { return }
        s.pendingSelection = nil
        fx.append(.applySelection(s.epoch, sel))
    }
}
