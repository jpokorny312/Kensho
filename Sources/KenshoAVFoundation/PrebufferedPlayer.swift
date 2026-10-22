import Foundation
import AVFoundation
import Kensho

/// A second player that gets the replacement of a stream ready **while the running one plays on**, so that the take-over is not a wait.
///
/// Why it exists. `AVPlayer.replaceCurrentItem(with:)` clears the layer at once, the new item then fetches its playlists, its first segments, decodes
/// its first frame, and AVPlayer waits "to minimize stalls" on top of that: on a real iPhone the picture stood still for five to nine seconds at every
/// change of stream, and `AVPlayerEngine`'s first answer to that - bring the replacement to `readyToPlay` on a silent player, then put a *copy* of the item
/// on the running one - saved only the master playlist (measured: a copy asks for the media again). What carries over from one player to the other is
/// not the item (AVFoundation refuses an item that has been on a player on another one: `NSInvalidArgumentException`, which nothing in Swift can catch) but
/// the **player**: this one has loaded the segments, has decoded and primed, and *becomes* the player (see `AVPlayerEngine.Options.prebuffer`).
///
/// What it does, in order:
/// 1. The item is told where to begin (`position`, a little ahead of the running player: where the replacement will be wanted when it is ready) and put
///    on a player of its own, silent and not waiting to minimize stalls (`preroll` and a start on the host clock need that).
/// 2. It waits for `readyToPlay`, jumps to `position` exactly, and waits until `bufferSeconds` are loaded from there.
/// 3. `preroll` primes the renderers: the first frame is decoded, the start is a start.
///
/// And when it is wanted, `align(to:)` jumps inside what is loaded (a few frames of work, not a fetch) to the exact place the running player will have
/// reached, and `start(at:hostTime:)` sets the new player going at the moment of the host clock at which the running one gets there - the one stops
/// where the other begins (see `AVPlayerEngine`'s hand-off).
@MainActor
public final class PrebufferedPlayer {
    public enum Failure: Error, Equatable {
        case timedOut(String)
        case itemFailed(String)
        case couldNotJump(TimeInterval)
        case cancelled
    }

    public struct Plan: Equatable, Sendable {
        /// Seconds loaded from the position before the item counts as ready.
        public var bufferSeconds: TimeInterval
        /// How far ahead of the position the item may load while it waits. The running player moves up to the place the item waits at, and the item has
        /// to have the part the running player will be at when the hand-off comes.
        public var forwardBufferSeconds: TimeInterval
        /// The whole preparation is given up after this long.
        public var timeout: TimeInterval
        /// Wait for the first frame to be ready for display (`firstFrameReady` says so) before the item counts as ready.
        public var waitsForFirstFrame: Bool

        public init(bufferSeconds: TimeInterval = 6, forwardBufferSeconds: TimeInterval = 11, timeout: TimeInterval = 40, waitsForFirstFrame: Bool = false) {
            self.bufferSeconds = bufferSeconds
            self.forwardBufferSeconds = forwardBufferSeconds
            self.timeout = timeout
            self.waitsForFirstFrame = waitsForFirstFrame
        }
    }

    /// The longest wait for the first frame (`Plan.waitsForFirstFrame`).
    static let firstFrameWait: TimeInterval = 2

    public let player: AVPlayer
    public let item: AVPlayerItem
    /// Where the item waits.
    public private(set) var position: TimeInterval
    private let plan: Plan
    private var isCancelled = false
    private weak var primingLayer: AVPlayerLayer?
    /// Said by whoever shows the picture of the player (a layer the player is on): nil, or not asked, when the plan does not wait for the first frame.
    public var firstFrameReady: (() -> Bool)?

    /// - Parameter player: a fresh player. It is configured here: silent, not on external playback, not waiting to minimize stalls.
    public init(item: AVPlayerItem, position: TimeInterval, plan: Plan, player: AVPlayer = AVPlayer()) {
        self.item = item
        self.position = max(0, position)
        self.plan = plan
        self.player = player
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        item.preferredForwardBufferDuration = plan.bufferSeconds + plan.forwardBufferSeconds
        // The item is told where to begin before it is on the player: otherwise it begins at 0, and AVPlayer fetches the first segments of the stream
        // for nothing.
        if self.position > 0 {
            item.seek(to: CMTime(seconds: self.position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
        player.replaceCurrentItem(with: item)
    }

    /// Where a player that waits beside `running` waits: a little ahead of where it is (the place the running player will have reached when the new
    /// one is ready), and less ahead when the running player has little buffered - it must not run dry before it gets there.
    ///
    /// - Parameters:
    ///   - startAt: where the playback is wanted at least (the owner's idea of the position; the running player's own time is used when it is later).
    public static func position(
        beside running: AVPlayer, startAt: TimeInterval = 0, settings: AVPlayerEngine.Options.Prebuffer = .init()
    ) -> TimeInterval {
        let current = running.currentTime().seconds
        let from = current.isFinite && current >= 0 ? current : startAt
        let ahead = loadedEnd(of: running.currentItem, containing: from).map { $0 - from } ?? 0
        // A running player that does not play (paused, or waiting for data) does not move on: the replacement waits right where it stands.
        let moves = running.rate > 0 && running.timeControlStatus == .playing
        let lead = moves ? min(settings.lead, max(0.25, ahead * 0.4)) : 0.25
        return max(startAt, from) + lead
    }

    /// A player for `item` that waits beside `running` (see `position(beside:startAt:settings:)`).
    public static func beside(
        _ running: AVPlayer, item: AVPlayerItem, startAt: TimeInterval = 0, settings: AVPlayerEngine.Options.Prebuffer = .init()
    ) -> PrebufferedPlayer {
        let position = position(beside: running, startAt: startAt, settings: settings)
        let lead = max(0.25, position - max(startAt, running.currentTime().seconds.isFinite ? running.currentTime().seconds : startAt))
        let plan = Plan(bufferSeconds: settings.bufferSeconds, forwardBufferSeconds: lead + 8, timeout: settings.timeout, waitsForFirstFrame: settings.waitsForFirstFrame)
        return PrebufferedPlayer(item: item, position: position, plan: plan)
    }

    /// Shows the player on `layer` while it waits (anywhere in a view hierarchy, a point in the corner will do, under the picture): a player that has no
    /// layer decodes no picture, and the first frame after the hand-over would be a decoder starting. With the layer the first frame is ready before the
    /// hand-over, and `Plan.waitsForFirstFrame` can wait for it.
    public func prime(on layer: AVPlayerLayer) {
        primingLayer = layer
        layer.player = player
        firstFrameReady = { [weak layer] in layer?.isReadyForDisplay ?? true }
    }

    /// Takes the player off the layer it was primed on (the owner has put it on its own layer: do this *after*, so that the picture never has no layer).
    public func unprime() {
        if let primingLayer, primingLayer.player === player { primingLayer.player = nil }
        primingLayer = nil
    }

    /// Ends the preparation (or the player's life): nothing is loaded for it any more, and the item is let go of.
    public func cancel() {
        unprime()
        isCancelled = true
        player.cancelPendingPrerolls()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Getting ready

    /// Brings the item to the place where a hand-off can be made without a wait: loaded, positioned, primed. Throws when it cannot be done in time.
    public func prepare() async throws {
        let deadline = Date().addingTimeInterval(plan.timeout)
        try await wait(until: deadline, "the item to be ready to play") { self.item.status != .unknown }
        guard item.status == .readyToPlay else { throw Failure.itemFailed(Self.describe(item.error)) }

        // The jump after `readyToPlay`, exact: the one before it only told the item where to begin.
        guard await jump(to: position) else { throw Failure.couldNotJump(position) }
        try await wait(until: deadline, "\(Int(plan.bufferSeconds)) s of the stream to be loaded") {
            self.item.status != .failed && self.bufferedAhead(from: self.position) >= min(self.plan.bufferSeconds, self.remaining(from: self.position))
        }
        guard item.status == .readyToPlay else { throw Failure.itemFailed(Self.describe(item.error)) }
        if plan.waitsForFirstFrame {
            // (A picture that does not come in two seconds - a layer that is nowhere to be seen, a decoder that is slow - costs a dark moment at the
            // hand-off, not the replacement.)
            do {
                try await wait(until: min(deadline, Date().addingTimeInterval(Self.firstFrameWait)), "the first frame to be ready") { self.firstFrameReady?() ?? true }
            } catch Failure.timedOut {
                // go on
            }
        }
        await preroll()
    }

    /// Jumps to `time` (exact) and primes the player there. Inside what is loaded this is a few frames of work; outside it the part has to be fetched,
    /// and the call waits for that (`waits`) - for a hand-off that is a wait on the viewer's side, which the caller decides to take or not.
    public func align(to time: TimeInterval, tail: TimeInterval, waits: TimeInterval = 8) async -> Bool {
        guard !isCancelled, item.status == .readyToPlay else { return false }
        let wasLoaded = bufferedAhead(from: time) >= min(tail, remaining(from: time))
        guard await jump(to: time) else { return false }
        position = time
        if !wasLoaded {
            let deadline = Date().addingTimeInterval(waits)
            try? await wait(until: deadline, "the part around \(time) s to be loaded") {
                self.item.status != .failed && self.bufferedAhead(from: time) >= min(tail, self.remaining(from: time))
            }
        }
        guard !isCancelled, item.status == .readyToPlay else { return false }
        await preroll()
        return bufferedAhead(from: time) > 0.25 || remaining(from: time) < 0.5
    }

    /// Sets the player going at `hostTime` of the host clock, at `time` of the item, at `rate`.
    public func start(at time: TimeInterval, hostTime: CMTime, rate: Float = 1) {
        player.setRate(rate, time: CMTime(seconds: time, preferredTimescale: 600), atHostTime: hostTime)
    }

    // MARK: - Taking over

    /// Seconds of the running player's time that the hand-over asks for to jump inside what is loaded and prime the player (a few frames of work; the rest
    /// is room for a busy main actor). The first round; a round that is late asks for more.
    static let alignSeconds = 0.8
    /// What must be loaded after the place of the hand-over.
    static let handOverTail = 2.0
    /// How far before the place this player waits at a running player that waits for data may stand for this one to take over from where it waits (the
    /// seconds between are not shown; a player that stands there shows nothing anyway).
    static let waitingReach = 4.0

    public enum HandOverOutcome: Equatable, Sendable {
        /// `flip` was called: this player is the one that plays now.
        case handedOver
        /// `isCurrent` said no, or the player was cancelled: nothing was handed over, and the running player is as it was (its item does not end at the place the
        /// hand-over was timed for any more).
        case cancelled
        /// It could not be done.
        case failed(String)
    }

    /// Hands the playback over from `old` to this player **at the moment `old` gets to the place this player is jumped to**: the old item ends there
    /// (`forwardPlaybackEndTime`) and this player is set going there on the host clock, so that the one stops where the other begins and the picture does
    /// not stand. `old` itself is not touched otherwise - when to let go of it is the owner's.
    ///
    /// The place is a little ahead of `old` (the time a jump inside what is loaded and a priming take: `alignSeconds`), at least where this player waits, and
    /// not past what `old` has loaded. A running player that waits for data (it ran dry) is not waited for: this player begins where it stands - or, when it
    /// stands a little before the place this player waits at, where this one waits (nothing earlier is loaded, and a jump back into what is not loaded is a
    /// fetch). A viewer who pauses (`isHeld`) gets this player put where `old` stopped, paused. A round that was late - `old` passed the place while the
    /// player was primed - is made again further ahead, up to four.
    ///
    /// **A place that is not loaded is not chased.** A jump out of what is loaded is a fetch - and for a transcode a new start of the server's encoder, which
    /// the running player outruns (a real iPhone, 2026-10-21: the replacement was ready after 19 s, the running player was 17 s ahead of what it had loaded,
    /// and four rounds of fetching in 24 s never got there; a jump 0.2 s back into what was not loaded hung for a minute). The hand-over then says so at
    /// once (`.failed`) and the owner goes the old way while whatever it prepared is still warm.
    ///
    /// - Parameters:
    ///   - aimedAt: the place this player was prepared for (it waits there, `position`), further ahead than a few seconds: the hand-over waits for `old` to
    ///     get there - as long as it plays, and not longer than it needs plus ten seconds - and is made at that place. nil: the place is `old`'s.
    ///   - isHeld: the viewer wants the playback paused; asked at every decision.
    ///   - isCurrent: false when a newer instruction has ended this hand-over.
    ///   - flip: called at the moment the picture must change (a few milliseconds before the start): the owner shows this player now. `playing` says whether
    ///     it is going or paused.
    public func handOver(
        from old: AVPlayer,
        aimedAt target: TimeInterval? = nil,
        isHeld: @MainActor () -> Bool,
        isCurrent: @MainActor () -> Bool,
        log: @MainActor (String) -> Void = { _ in },
        flip: @MainActor (_ playing: Bool) -> Void
    ) async -> HandOverOutcome {
        let oldItem = old.currentItem
        let began = ProcessInfo.processInfo.systemUptime
        var workBegan = began

        // A place far ahead: the running player plays on until it is about to get there.
        if let target {
            let now0 = old.currentTime().seconds
            guard now0.isFinite else { return .failed("the running player has no time") }
            let speed0 = old.rate > 0 ? Double(old.rate) : 1
            let arrivalLimit = began + max(0, target - now0) / speed0 * 1.5 + 10
            var ranDryAt: TimeInterval?
            while true {
                guard !isCancelled, isCurrent() else { return .cancelled }
                let now = old.currentTime().seconds
                guard now.isFinite else { return .failed("the running player has no time") }
                let wantsToPlay = !isHeld() && old.rate > 0
                let speed = old.rate > 0 ? Double(old.rate) : 1
                if !wantsToPlay || now >= target - Self.alignSeconds * 1.5 * speed { break }
                let uptime = ProcessInfo.processInfo.systemUptime
                if old.timeControlStatus == .playing {
                    ranDryAt = nil
                } else {
                    // It waits for data. Close to the place this player waits at it is the way on (below); far before it, it is a wait that may be over in a
                    // moment - and not for long: a player that stood for six seconds a good way before the place will not get there.
                    if target - now <= 4 { break }
                    ranDryAt = ranDryAt ?? uptime
                    if uptime - (ranDryAt ?? uptime) > 6 { return .failed(String(format: "the running player ran dry at %.1f s, far before the place %.1f s", now, target)) }
                }
                if uptime > arrivalLimit { return .failed(String(format: "the running player did not get to the place %.1f s in time (at %.1f s)", target, now)) }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            workBegan = ProcessInfo.processInfo.systemUptime
        }

        for round in 0..<4 {
            guard !isCancelled, isCurrent() else { return .cancelled }
            guard ProcessInfo.processInfo.systemUptime - workBegan < 12 else { return .failed("the hand-over took too long") }
            let now = old.currentTime().seconds
            guard now.isFinite else { return .failed("the running player has no time") }
            let wantsToPlay = !isHeld() && old.rate > 0
            let playing = wantsToPlay && old.timeControlStatus == .playing
            // A viewer who watches at another speed: the place is ahead by media seconds, the wait is in wall-clock seconds.
            let speed = old.rate > 0 ? Double(old.rate) : 1

            // The place: ahead by what a jump inside the loaded part and a priming take, more with each round that was late ...
            var place = now
            if playing {
                place = now + Self.alignSeconds * Double(round + 1) * speed
                // ... not past what the running player has loaded (it would stand there before it got to the place) ...
                if let reach = Self.loadedEnd(of: oldItem, containing: now), place > reach - 0.1 { place = max(now + 0.15, reach - 0.1) }
                // ... and not before the place this player waits at: it has nothing earlier loaded.
                place = max(place, position)
            } else {
                // (A running player that waits for data, or is paused: this player begins where it stands - jumping ahead to what is loaded would skip what it
                // never showed - but not before the place it waits at: a jump back out of what is loaded is a fetch, and a standing player is not outrun
                // by anything but that fetch.)
                // And not when this player waits far ahead of where the running one stands (a viewer who paused while the hand-over waited for a place some
                // seconds on): the picture would jump over what the viewer has not seen.
                if position - now > Self.waitingReach {
                    return .failed(String(format: "this player waits at %.1f s, %.1f s ahead of the running player that does not play (it is at %.1f s)", position, position - now, now))
                }
                if position > now { place = position } else { place = max(now, position) }
            }
            // A place that is not loaded is not chased (a jump out of what is loaded is a fetch, which a running player outruns): a short wait for the loader,
            // which goes on forward by itself, and then the owner is told.
            if !covers(place) {
                _ = try? await wait(until: Date().addingTimeInterval(2.5), "the part around the place to be loaded") { self.covers(place) || self.item.status == .failed }
                guard !isCancelled, isCurrent() else { return .cancelled }
                if !covers(place) {
                    let bounds = loaded
                    return .failed(String(format: "the place %.1f s is not loaded (this player has %.1f to %.1f s)", place, bounds?.lowerBound ?? position, bounds?.upperBound ?? position))
                }
            }
            guard await align(to: place, tail: Self.handOverTail, waits: 0) else {
                return isCancelled || !isCurrent() ? .cancelled : .failed("could not jump to \(place) s")
            }
            guard !isCancelled, isCurrent() else { return .cancelled }

            if isHeld() || !wantsToPlay {
                // Paused (by the viewer, now or while this player was made ready): it is put where the running player stands, and nothing starts.
                let stands = max(old.currentTime().seconds, position)
                if abs(stands - place) > 0.02 {
                    guard covers(stands) else { return .failed("could not jump to \(stands) s") }
                    guard await align(to: stands, tail: Self.handOverTail, waits: 0) else { return .failed("could not jump to \(stands) s") }
                }
                guard !isCancelled, isCurrent() else { return .cancelled }
                log(String(format: "hand-over at %.2f s: the viewer has the playback paused, this one waits there", stands))
                flip(false)
                return .handedOver
            }
            if !playing {
                log(String(format: "hand-over at %.2f s: the running player waits for data (it is at %.2f s), this one begins at once", place, now))
                startAtOnce(at: place, replacing: old, rate: Float(speed))
                flip(true)
                return .handedOver
            }
            let after = old.currentTime().seconds
            if after > place - 0.06 * speed { continue }                  // the running player has passed the place meanwhile: another round, further ahead
            let wait = (place - after) / speed
            log(String(format: "hand-over at %.2f s: the running player is at %.2f s, in %.2f s (round %d, %.2f s of work)", place, after, wait, round + 1,
                       ProcessInfo.processInfo.systemUptime - workBegan))
            // The one stops where the other begins: the item ends at `place`, this player starts there on the host clock. (A player pauses at the end of
            // its item - `actionAtItemEnd` is `.pause` unless the owner chose otherwise - and keeps it: a wake-up that is late, the main actor being busy,
            // finds the item still there, and the hand-over is late, not lost.)
            let hostAt = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: wait, preferredTimescale: 1_000_000_000))
            oldItem?.forwardPlaybackEndTime = CMTime(seconds: place, preferredTimescale: 600)
            start(at: place, hostTime: hostAt, rate: Float(speed))
            // The picture changes just before the start, so that this player's - its first frame, waiting at `place` - is the one on the screen when the
            // running item ends.
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait - 0.012) * 1_000_000_000))
            guard !isCancelled, isCurrent() else {
                await giveTheEndBack(of: oldItem, on: old, isHeld: isHeld)
                return .cancelled
            }
            if isHeld() {
                // The viewer paused while this player waited for its moment: the start on the host clock is called off, and it is put where the running
                // player stopped (the picture it shows paused is the one the viewer paused on).
                player.pause()
                let stands = old.currentTime().seconds
                if stands.isFinite, abs(stands - place) > 0.05, covers(stands) { _ = await align(to: stands, tail: Self.handOverTail, waits: 0) }
                guard !isCancelled, isCurrent() else {
                    await giveTheEndBack(of: oldItem, on: old, isHeld: isHeld)
                    return .cancelled
                }
                flip(false)
                return .handedOver
            }
            flip(true)
            return .handedOver
        }
        return .failed("the running player was past the place four times")
    }

    /// A hand-over that is called off after the old item was told to end at the place: the item ends where the viewer wants it to - not there. When it has got
    /// to the place meanwhile (the end is taken back a few milliseconds before it is reached, and AVFoundation may have decided by then that the item ends:
    /// a moment later it shows) and is the player's still, it plays on - unless the viewer holds it, or the owner is done with the player.
    private func giveTheEndBack(of item: AVPlayerItem?, on old: AVPlayer, isHeld: @MainActor () -> Bool) async {
        item?.forwardPlaybackEndTime = .invalid
        guard !isCancelled else { return }
        try? await Task.sleep(nanoseconds: 120_000_000)
        if !isCancelled, !isHeld(), old.currentItem === item, old.rate == 0 { old.play() }
    }

    /// Hands the playback over to this player **as it waits**: the running player stops and this one begins at the place it waits at. For a stream on a
    /// timeline of its own - the next episode, the one the viewer chose - where no place is shared with the running player and nothing is aligned: what
    /// `handOver(from:...)` does for the same stream in another quality. The running player plays on until the call is made (the viewer sees the credits,
    /// not a black picture, while the next episode is got ready), and the cut is the one frame it takes this player to start.
    ///
    /// - Parameters:
    ///   - isCurrent: false when a newer instruction has ended this hand-over (checked once, at the moment of the cut).
    ///   - flip: called at the moment the picture must change: the owner shows this player now. It plays from here on.
    public func cutOver(from old: AVPlayer, isCurrent: @MainActor () -> Bool, flip: @MainActor () -> Void) async -> HandOverOutcome {
        guard !isCancelled, isCurrent() else { return .cancelled }
        guard item.status == .readyToPlay else { return .failed("the item is not ready") }
        // (The preparation put it where it waits and primed it; nothing has moved it since.)
        startAtOnce(at: position, replacing: old, rate: old.defaultRate > 0 ? old.defaultRate : 1)
        flip()
        return .handedOver
    }

    /// Starts here at `time` in a moment (the running player is stopped): a hand-over to a player that waits for data, or one that starts at once.
    private func startAtOnce(at time: TimeInterval, replacing old: AVPlayer, rate: Float) {
        let hostAt = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.03, preferredTimescale: 1_000_000_000))
        start(at: time, hostTime: hostAt, rate: rate)
        old.pause()
    }

    /// The end of the loaded part of `item` that contains `time`.
    static func loadedEnd(of item: AVPlayerItem?, containing time: TimeInterval) -> TimeInterval? {
        guard let item else { return nil }
        for range in item.loadedTimeRanges.map(\.timeRangeValue) where range.isValid {
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            if start <= time + 0.25, time < end { return end }
        }
        return nil
    }

    // MARK: - What is loaded

    /// Seconds loaded from `time` on (0 when `time` is not inside a loaded part).
    public func bufferedAhead(from time: TimeInterval) -> TimeInterval {
        for range in item.loadedTimeRanges.map(\.timeRangeValue) where range.isValid {
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            if start <= time + 0.1, time < end { return end - time }
        }
        return 0
    }

    /// Whether `time` is inside what is loaded, with the tail a hand-over needs after it (or the end of the stream).
    func covers(_ time: TimeInterval) -> Bool {
        bufferedAhead(from: time) >= min(Self.handOverTail, remaining(from: time))
    }

    /// How much of the stream is left from `time` on (a stream whose length is not known yet: a lot).
    public func remaining(from time: TimeInterval) -> TimeInterval {
        item.duration.isNumeric ? max(0, item.duration.seconds - time) : .greatestFiniteMagnitude
    }

    /// Where a hand-off can be made: from the place the item waits at to the end of what is loaded of it.
    public var loaded: ClosedRange<TimeInterval>? {
        for range in item.loadedTimeRanges.map(\.timeRangeValue) where range.isValid {
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            if start <= position + 0.1, position < end { return start...end }
        }
        return nil
    }

    // MARK: - Pieces

    /// Jumps the item to `time`, exact. A jump that does not come back in `timeout` seconds is cancelled (a seek of an HLS item that has to fetch from a
    /// server that does not answer never completes by itself) and counts as no jump.
    private func jump(to time: TimeInterval, timeout: TimeInterval = 4) async -> Bool {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<3 where !isCancelled {
            let item = self.item
            let done = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = ResumeOnce(continuation)
                item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in once.resume(finished) }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    if !once.isResumed {
                        item.cancelPendingSeeks()
                        once.resume(false)
                    }
                }
            }
            if done { return true }
            if ProcessInfo.processInfo.systemUptime - began > timeout * 1.5 { break }
        }
        return false
    }

    /// Primes the player. It needs a player that is ready and not going (`preroll` raises an exception for the others).
    private func preroll() async {
        guard !isCancelled, item.status == .readyToPlay, player.rate == 0, !player.automaticallyWaitsToMinimizeStalling else { return }
        await withTaskCancellationHandler {
            _ = await player.preroll(atRate: 1)
        } onCancel: { [player] in
            player.cancelPendingPrerolls()
        }
    }

    private func wait(until deadline: Date, _ what: String, _ condition: () -> Bool) async throws {
        while !condition() {
            if isCancelled || Task.isCancelled { throw Failure.cancelled }
            if Date() > deadline { throw Failure.timedOut(what) }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "unknown failure" }
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }
}

/// Resumes a continuation once, from whichever thread gets there first (the completion of a seek and the timer that gives it up).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    var isResumed: Bool { lock.withLock { continuation == nil } }

    func resume(_ value: Bool) {
        let taken = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
