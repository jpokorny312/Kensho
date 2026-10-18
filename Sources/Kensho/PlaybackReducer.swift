import Foundation

public struct PlaybackPolicy: Sendable {
    /// Minimum time between two quality swaps. Every swap is a new engine
    /// session (a visible moment when it takes over), so letting the ladder
    /// flap is worse than staying one rung too low for a while.
    public var qualityCooldown: TimeInterval
    public init(qualityCooldown: TimeInterval = 30) {
        self.qualityCooldown = qualityCooldown
    }
}

/// The single place that decides what playback does next. Pure on purpose:
/// no engine, no clock, no threads - events in, state and effects out.
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
            discardSwap(&s, &fx)
            s.epoch = allocateEpoch(&s)
            s.phase = .loading
            s.wantsPlay = true
            s.source = source
            s.quality = quality
            s.selection = selection
            s.position = max(0, startAt)
            s.pendingSeek = nil
            s.pendingSelection = nil
            s.lostWhileSwapping = nil
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
            // Only from a steady moment, and one replacement at a time.
            guard s.isSteady, s.swap == nil, choice != s.quality else { break }
            // AVPlayer cannot move between SDR, HDR10 and Dolby Vision inside
            // one item, and a range change is a visible display-mode switch.
            if let current = s.quality?.range ?? s.source?.range, current != choice.range { break }
            if let last = s.lastQualityChange, now - last < policy.qualityCooldown { break }
            // The running session plays on - it keeps its epoch, its ticks and its stalls count - while the replacement gets its own.
            let epoch = allocateEpoch(&s)
            s.swap = PendingSwap(epoch: epoch, quality: choice, isReady: false)
            s.lastQualityChange = now
            fx.append(.prepareSwap(epoch, choice, startAt: s.position, selection: s.selection))

        case .stop:
            guard s.phase != .idle, s.phase != .stopped else { break }
            discardSwap(&s, &fx)
            let old = s.epoch
            s.epoch = allocateEpoch(&s)
            s.phase = .stopped
            s.wantsPlay = false
            s.pendingSeek = nil
            s.pendingSelection = nil
            s.lostWhileSwapping = nil
            fx.append(.stop(old))

        case let .engineReady(e):
            guard e == s.epoch, s.phase == .loading else { break }
            settle(&s, &fx)

        case let .swapPrepared(e):
            guard let swap = s.swap, swap.epoch == e else { break }
            if s.phase == .seeking {
                // A jump is on its way: the replacement takes over when it has landed, from where it landed.
                s.swap?.isReady = true
            } else {
                commit(&s, &fx)
            }

        case let .swapFailed(e, reason):
            guard let swap = s.swap, swap.epoch == e else { break }
            s.swap = nil
            // If the running session had died in the meantime, the replacement was the way on: there is none.
            if let lost = s.lostWhileSwapping {
                s.lostWhileSwapping = nil
                s.phase = .failed(lost.isEmpty ? reason : lost)
            }

        case let .swapFinished(e):
            guard e == s.epoch, s.phase == .switching else { break }
            settle(&s, &fx)

        case let .seekFinished(e, token):
            guard e == s.epoch, s.phase == .seeking, token == s.seekToken else { break }
            s.phase = s.wantsPlay ? .playing : .paused
            if s.swap?.isReady == true {
                // The replacement was waiting for the jump to land: it takes over from here (and plays, if the viewer wants it).
                s.pendingSelection = nil
                commit(&s, &fx)
            } else {
                flushSelection(&s, &fx)
                if s.wantsPlay { fx.append(.play(s.epoch)) }
            }

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
            if s.swap != nil {
                // A replacement is on its way: it is the way on. Nothing plays until it takes over.
                s.lostWhileSwapping = reason
                s.phase = .switching
                // (One that only waited for a jump to land waits for nothing now: that jump will not land on a session that is gone.)
                if s.swap?.isReady == true { commit(&s, &fx) }
            } else {
                s.phase = .failed(reason)
            }
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

    /// Every session ever asked for has an epoch of its own, whether it is live
    /// yet or not: a replacement being prepared must not share a number with
    /// whatever the viewer loads in the meantime.
    private static func allocateEpoch(_ s: inout PlaybackState) -> Epoch {
        s.lastIssuedEpoch = s.lastIssuedEpoch.next()
        return s.lastIssuedEpoch
    }

    /// The replacement takes over: the running session ends, the replacement
    /// is the live one, and it is told to begin at the position NOW.
    private static func commit(_ s: inout PlaybackState, _ fx: inout [PlaybackEffect]) {
        guard let swap = s.swap else { return }
        let old = s.epoch
        s.swap = nil
        s.epoch = swap.epoch
        s.quality = swap.quality
        s.phase = .switching
        s.pendingSelection = nil
        s.lostWhileSwapping = nil
        fx.append(.commitSwap(swap.epoch, replacing: old, at: s.position, selection: s.selection))
    }

    /// A prepared replacement that will not be used.
    private static func discardSwap(_ s: inout PlaybackState, _ fx: inout [PlaybackEffect]) {
        guard let swap = s.swap else { return }
        s.swap = nil
        fx.append(.discardSwap(swap.epoch))
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
