import Foundation
import AVFoundation
import Kensho

/// Plays the instructions of a `PlaybackCoordinator` on an `AVPlayer`.
///
/// Every report it makes carries the epoch of the instruction that started
/// the item it is talking about, so the reducer can drop what a replaced
/// item says late.
///
/// A quality change is made before it is broken: `prepareSwap` brings the
/// replacement's item to `readyToPlay` on a second, silent player while
/// `player` plays on, and only `commitSwap` puts it on `player`.
///
/// What the engine reports as a stall is playback that was running and ran
/// dry (see `StallWatch`), not the wait for the first data after `play()`, a
/// seek or a swap: AVPlayer shows `waitingToPlayAtSpecifiedRate` for every one
/// of those, and a quality policy that took each for a weak link would step
/// down for nothing.
@MainActor
public final class AVPlayerEngine: PlaybackEngine {
    public var onEvent: ((PlaybackEvent) -> Void)?
    public let player: AVPlayer

    /// What the provider is asked for: a source at a quality, wanted at a position and with these tracks. A stream that can begin where it is
    /// wanted need not begin at the start and be jumped; a server's transcode has the tracks in its address.
    public struct ItemRequest: Equatable, Sendable {
        public var source: MediaSource
        public var quality: QualityChoice?
        /// Where the item is wanted: the start position of a load, and for a replacement the position when it was asked for (the engine
        /// jumps to the exact one when the replacement takes over).
        public var startAt: TimeInterval
        public var selection: TrackSelection

        public init(source: MediaSource, quality: QualityChoice?, startAt: TimeInterval, selection: TrackSelection) {
            self.source = source
            self.quality = quality
            self.startAt = startAt
            self.selection = selection
        }
    }

    /// Resolves what to hand AVPlayer for a request. Typically starts the
    /// PrismCore session (or builds the server URL) and returns the item for
    /// the playlist address. It must be an item that is on no player: AVFoundation
    /// raises an exception that nothing in Swift can catch for one that is. Throwing
    /// reports a failure for that epoch.
    public typealias ItemProvider = @MainActor (ItemRequest) async throws -> AVPlayerItem
    /// Applies the viewer's track choice to an item. The default maps the
    /// numbers to option positions inside AVFoundation's audible and legible
    /// groups; an app that maps stream indices differently passes its own.
    /// Calls for one session never overlap and never run in the wrong order.
    public typealias SelectionApplier = @MainActor (AVPlayerItem, TrackSelection) async -> Void

    /// Where the default does not fit the engine's owner.
    public struct Options: Equatable, Sendable {
        /// An item is played as soon as it is on the player, not when the state machine has the session at its start position and says `play`.
        /// For an owner that must not wait for its item - CarPlay's: the car shows its picture when the player plays, and a player that waited for the
        /// car to answer first would keep the car waiting for the player. The start position is then the provider's business (an item that was told where
        /// to begin, `AVPlayerItem.seek(to:completionHandler:)` before it loads): the engine neither jumps to it nor waits for a jump. Applies to a
        /// `load` and not to a quality replacement (which takes over paused and plays when the state machine says so). The reducer holds the player
        /// with a `pause` where the viewer pauses while the item loads.
        public var startsPlayingAtOnce: Bool
        /// How exactly the jumps of the viewer land.
        public var jumps: Jumps
        public enum Jumps: Equatable, Sendable {
            /// To the position asked for (the default; what a start position and a skip of a segment need).
            case exact
            /// Where AVPlayer lands most cheaply: at a keyframe or a segment start of a stream that is made of segments, without the cost of decoding up to
            /// the exact position. (Measured on an HLS stream of audio: on the second where the part is loaded already, at the start of its segment where it
            /// is not - 13.0 s lands at 12.005 s - and no different from the plain `seek(to:)`. For video: keyframes, not measured.)
            case cheapest
        }

        public init(startsPlayingAtOnce: Bool = false, jumps: Jumps = .exact) {
            self.startsPlayingAtOnce = startsPlayingAtOnce
            self.jumps = jumps
        }
    }

    /// How often a seek that ended without the reducer having asked for a newer
    /// one is tried again before the session is given up.
    private static let maxSeekAttempts = 3

    /// What one epoch stands for on this engine.
    @MainActor
    private final class Session {
        enum Stage {
            /// The provider is making the item.
            case resolving
            /// A replacement's item is on the staging player and not ready yet.
            case loading
            /// A replacement is ready and waits for `commitSwap`.
            case prepared
            /// On `player`, getting to its start position.
            case starting
            case running
        }

        struct SeekRequest {
            var token: SeekToken
            var target: TimeInterval
            var attempts: Int
        }

        let epoch: Epoch
        /// This session plays as soon as its item is on the player (`Options.startsPlayingAtOnce`; set for a load).
        var startsAtOnce = false
        /// The reducer has told the session to hold (`pause`) and not to go (`play`) since: an item that arrives now is not set going, whatever
        /// `startsAtOnce` says. (The viewer who pauses while the item loads.)
        var held = false
        /// What the reducer is told when the session is at its position: a
        /// fresh load is `engineReady`, a replacement that took over is
        /// `swapFinished`.
        let atPosition: (Epoch) -> PlaybackEvent
        var stage: Stage = .resolving
        var item: AVPlayerItem?
        var startAt: TimeInterval = 0
        var selection = TrackSelection()
        /// The choice the applier carried out last (nil: none yet). The next one is judged against it: "no subtitle" after a subtitle is the viewer's "off".
        var applied: TrackSelection?
        var seek: SeekRequest?
        var hasFailed = false
        var statusObservation: NSKeyValueObservation?
        var failureObserver: NSObjectProtocol?
        var resolveTask: Task<Void, Never>?
        var startTask: Task<Void, Never>?
        var selectionTask: Task<Void, Never>?

        init(epoch: Epoch, atPosition: @escaping (Epoch) -> PlaybackEvent) {
            self.epoch = epoch
            self.atPosition = atPosition
        }

        func end() {
            resolveTask?.cancel()
            startTask?.cancel()
            selectionTask?.cancel()
            statusObservation = nil
            if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
            failureObserver = nil
        }
    }

    private let provider: ItemProvider
    /// What applies a choice to an item: the app's own applier, or the default, which also wants to know what was applied before (see `applyDefault`).
    private let applier: @MainActor (AVPlayerItem, TrackSelection, _ previous: TrackSelection?) async -> Void
    private let options: Options
    private let log: KenshoLog
    /// The session whose item is on `player`.
    private var live: Session?
    /// The replacement being made; `player` plays on while it is.
    private var replacement: Session?
    /// What the live session was loaded from; a replacement is the same source
    /// at another quality.
    private var source: MediaSource?
    /// Where a replacement's item gets ready. An item loads only on a player,
    /// and `player` is busy.
    private lazy var staging: AVPlayer = {
        isStagingCreated = true
        let staging = AVPlayer()
        staging.isMuted = true
        staging.allowsExternalPlayback = false
        return staging
    }()
    private var isStagingCreated = false
    private var rateObservation: NSKeyValueObservation?
    private var rateChangeObserver: NSObjectProtocol?
    /// What the engine last asked of the player: playing or not. A rate that is something else was changed by someone else.
    private var expectsPlaying = false
    private var stallWatch = StallWatch()
    private var timeObserver: Any?

    /// - Parameter log: where a failed session is written in full (domain, code and
    ///   everything nested), under the tag `kensho`. The report to the reducer carries only a line.
    public init(
        player: AVPlayer = AVPlayer(),
        provider: @escaping ItemProvider,
        applier: SelectionApplier? = nil,
        options: Options = Options(),
        log: KenshoLog = .silent
    ) {
        self.player = player
        self.provider = provider
        if let applier {
            self.applier = { item, selection, _ in await applier(item, selection) }
        } else {
            self.applier = { item, selection, previous in await AVPlayerEngine.applyDefault(item, selection, after: previous) }
        }
        self.options = options
        self.log = log
        observePlayer()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let rateChangeObserver { NotificationCenter.default.removeObserver(rateChangeObserver) }
    }

    public func perform(_ effect: PlaybackEffect) {
        switch effect {
        case let .load(epoch, source, startAt, selection, quality):
            endReplacement()
            endLive()
            // What the viewer was looking at stays on the player, paused, until
            // the new item can take its place: nothing is torn down early.
            expectsPlaying = false
            player.pause()
            self.source = source
            let session = Session(epoch: epoch, atPosition: { .engineReady($0) })
            session.startsAtOnce = options.startsPlayingAtOnce
            session.startAt = startAt
            session.selection = selection
            live = session
            resolve(session, source: source, quality: quality)

        case let .prepareSwap(epoch, quality, startAt, selection):
            endReplacement()
            guard let source else {
                onEvent?(.swapFailed(epoch, reason: "nothing is loaded to make a replacement of"))
                return
            }
            let session = Session(epoch: epoch, atPosition: { .swapFinished($0) })
            session.startAt = startAt
            session.selection = selection
            replacement = session
            resolve(session, source: source, quality: quality)

        case let .commitSwap(epoch, replacing, at, selection):
            guard let session = replacement, session.epoch == epoch, session.stage == .prepared, let prepared = session.item else {
                onEvent?(.engineFailed(epoch, reason: "no prepared session \(epoch.rawValue) to take over from \(replacing.rawValue)"))
                return
            }
            // Where the player is, not where the last tick said: the reducer's position is up to half a second old.
            let measured = player.currentTime().seconds
            replacement = nil
            endLive()
            live = session
            session.startAt = measured.isFinite && abs(measured - at) < 5 ? measured : at
            session.selection = selection
            // The prepared item has done its job - it proved on the staging player that the stream
            // loads - and cannot go any further: AVFoundation refuses an item that has been on one
            // player on another (NSInvalidArgumentException, even after it was taken off the first,
            // and an exception through Swift's async frames ends the process). A copy has the same
            // asset - the master playlist is not asked for again; the media is, measured on an HLS
            // stream (AVPlayerEngineHLSTests) - and the same settings, the choice of tracks among them.
            session.statusObservation = nil
            staging.replaceCurrentItem(with: nil)
            let item = (prepared.copy() as? AVPlayerItem) ?? AVPlayerItem(asset: prepared.asset)
            attachToPlayer(session, item: item)

        case let .discardSwap(epoch):
            guard replacement?.epoch == epoch else { return }
            endReplacement()

        case let .play(epoch):
            guard let session = live, session.epoch == epoch else { return }
            session.held = false
            expectsPlaying = true
            player.play()

        case let .pause(epoch):
            guard let session = live, session.epoch == epoch else { return }
            session.held = true
            expectsPlaying = false
            player.pause()

        case let .seek(epoch, token, target):
            guard let session = live, session.epoch == epoch else { return }
            guard session.stage == .running else {
                // The reducer holds a seek back until the session is at its position. One that comes
                // earlier is a mistake somewhere else, and an answer is owed all the same.
                onEvent?(.engineFailed(epoch, reason: "asked to seek before the session was at its position"))
                return
            }
            session.seek = Session.SeekRequest(token: token, target: target, attempts: 0)
            runSeek(of: session)

        case let .applySelection(epoch, selection):
            guard let session = live, session.epoch == epoch, session.stage == .running, let item = session.item else { return }
            // Each call carries the whole choice, so only the newest matters - but the older one may
            // be half way through and must be out of the way before the newer starts, or the older
            // can finish last and leave the item on the choice the viewer has already replaced.
            let previous = session.selectionTask
            previous?.cancel()
            session.selectionTask = Task { [weak self, weak session] in
                await previous?.value
                guard !Task.isCancelled, let self, let session, session === self.live else { return }
                // Another audio rendition makes AVPlayer drop what it had and wait for the other; the wait that follows is the viewer's choice, not a stream
                // that ran dry (and a quality policy that took it for one would step down for nothing).
                self.stallWatch.trackChanged(now: ProcessInfo.processInfo.systemUptime)
                await self.applier(item, selection, session.applied)
                session.applied = selection
                self.stallWatch.trackChanged(now: ProcessInfo.processInfo.systemUptime)
            }

        case .stop:
            endReplacement()
            endLive()
            source = nil
            expectsPlaying = false
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    // MARK: - Making a session

    /// Asks the provider for the session's item. A newer instruction ends the
    /// session; what the provider returns after that is dropped.
    private func resolve(_ session: Session, source: MediaSource, quality: QualityChoice?) {
        session.resolveTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let item = try await self.provider(ItemRequest(source: source, quality: quality, startAt: session.startAt, selection: session.selection))
                guard !Task.isCancelled, self.isCurrent(session) else { return }
                if item === self.player.currentItem || (self.isStagingCreated && item === self.staging.currentItem) {
                    self.fail(session, reason: "the provider returned an item that is on a player already")
                    return
                }
                if session === self.live {
                    self.attachToPlayer(session, item: item)
                } else {
                    self.attachToStaging(session, item: item)
                }
            } catch {
                guard !Task.isCancelled, self.isCurrent(session) else { return }
                self.fail(session, error: error)
            }
        }
    }

    private func isCurrent(_ session: Session) -> Bool {
        session === live || session === replacement
    }

    /// Puts the item on `player`, paused: a session starts where it is told to
    /// and plays when the reducer says so. AVPlayer keeps its rate across
    /// `replaceCurrentItem`, so without the pause an item that replaces a
    /// playing one starts playing by itself. (A session that starts at once - see
    /// `Options.startsPlayingAtOnce` - is set going as the item goes on.)
    private func attachToPlayer(_ session: Session, item: AVPlayerItem) {
        session.stage = .starting
        session.item = item
        observeStatus(of: session, item: item)
        session.failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self, weak session] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, let session, session === self.live else { return }
                self.fail(session, error: error)
            }
        }
        let setsGoing = session.startsAtOnce && !session.held
        expectsPlaying = setsGoing
        player.pause()
        player.replaceCurrentItem(with: item)
        if setsGoing { player.play() }
    }

    private func attachToStaging(_ session: Session, item: AVPlayerItem) {
        session.stage = .loading
        session.item = item
        observeStatus(of: session, item: item)
        staging.replaceCurrentItem(with: item)
    }

    /// The status stays observed for as long as the session lives: an item that
    /// is ready can still fail, and a stream that dies while it plays is the
    /// failure that matters most.
    private func observeStatus(of session: Session, item: AVPlayerItem) {
        session.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak session] observed, _ in
            let status = observed.status
            let error = observed.error
            Task { @MainActor in
                // (The item the report is about is the one the session has: a report of the item on the staging player that is still on its way when
                // the session has taken a copy over is no report about the copy.)
                guard let self, let session, session.item === observed, self.isCurrent(session) else { return }
                self.itemStatusChanged(session, status: status, error: error)
            }
        }
    }

    private func itemStatusChanged(_ session: Session, status: AVPlayerItem.Status, error: Error?) {
        switch (status, session.stage) {
        case (.readyToPlay, .loading):
            session.stage = .prepared
            onEvent?(.swapPrepared(session.epoch))
        case (.readyToPlay, .starting):
            start(session)
        case (.failed, _):
            fail(session, error: error)
        default:
            break
        }
    }

    /// Gets a session that is on the player to its start position and reports it.
    private func start(_ session: Session) {
        guard session.startTask == nil, let item = session.item else { return }
        session.startTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            // (A session that starts at once is positioned by its item, which was told where to begin.)
            if session.startAt > 0, !session.startsAtOnce {
                let time = CMTime(seconds: self.clamped(session.startAt, in: item), preferredTimescale: 600)
                var landed = false
                for _ in 0..<Self.maxSeekAttempts where !landed {
                    landed = await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    guard !Task.isCancelled, session === self.live else { return }
                }
                guard landed else {
                    self.fail(session, reason: "could not get to the start position \(session.startAt)")
                    return
                }
            }
            await self.applier(item, session.selection, session.applied)
            session.applied = session.selection
            guard !Task.isCancelled, session === self.live else { return }
            session.stage = .running
            self.onEvent?(session.atPosition(session.epoch))
        }
    }

    private func runSeek(of session: Session) {
        guard var request = session.seek else { return }
        request.attempts += 1
        session.seek = request
        let time = CMTime(seconds: clamped(request.target, in: session.item), preferredTimescale: 600)
        // Zero tolerance by default: a keyframe-snapped seek lands a few seconds
        // off the target and the picture jumps back after it. (`Options.jumps` can ask for the cheap landing.)
        let tolerance: CMTime = options.jumps == .exact ? .zero : .positiveInfinity
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak session] finished in
            Task { @MainActor in
                // A newer seek replaced this one (its token is the one in `session.seek` now), or the
                // session is gone: the newer one answers, and reporting this one would report a
                // position the player never reached.
                guard let self, let session, session === self.live, session.seek?.token == request.token else { return }
                if finished {
                    session.seek = nil
                    // (The wait that began during the jump and goes on is a start from here.)
                    self.stallWatch.seekLanded(now: ProcessInfo.processInfo.systemUptime)
                    self.watchTheGrace()
                    self.onEvent?(.seekFinished(session.epoch, request.token))
                } else if request.attempts < Self.maxSeekAttempts {
                    // Nothing newer was asked for, yet AVPlayer ended it: something else moved the
                    // player. Without an answer the reducer would wait in `.seeking` for good.
                    self.runSeek(of: session)
                } else {
                    session.seek = nil
                    self.fail(session, reason: "the seek to \(request.target) did not complete after \(request.attempts) attempts")
                }
            }
        }
    }

    /// A session that cannot go on: a replacement is given up (the live one
    /// plays on), the live one is reported to the reducer.
    private func fail(_ session: Session, error: Error?) {
        log.log("session \(session.epoch.rawValue) failed: \(ErrorDescription.describe(error as NSError?))", tag: "kensho")
        fail(session, reason: Self.reason(for: error))
    }

    private func fail(_ session: Session, reason: String) {
        guard !session.hasFailed else { return }
        session.hasFailed = true
        if session === replacement {
            endReplacement()
            onEvent?(.swapFailed(session.epoch, reason: reason))
        } else if session === live {
            onEvent?(.engineFailed(session.epoch, reason: reason))
        }
    }

    private func endLive() {
        live?.end()
        live = nil
    }

    private func endReplacement() {
        guard let session = replacement else { return }
        replacement = nil
        session.end()
        if session.item != nil { staging.replaceCurrentItem(with: nil) }
    }

    // MARK: - What the player says

    private func observePlayer() {
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                // Every change is seen, also those of a session that is not running yet: what the
                // status was before is what tells a stall from a start. The reducer ignores both
                // reports outside the phases they apply to.
                let now = ProcessInfo.processInfo.systemUptime
                let report = self.stallWatch.observe(status, seekInFlight: self.live?.seek != nil, now: now)
                self.report(report)
                if status == .waitingToPlayAtSpecifiedRate { self.watchTheGrace() }
            }
        }
        // A change of the rate the engine did not ask for: AVPlayer stops by itself for an interruption of the audio session (a call, Siri), for the app
        // going to the background, for a route that goes away - and anything that holds the player can start or stop it. The reducer has to hear of
        // it as the viewer's pause or play: it would go on thinking the film plays, and its next `play` would be no instruction at all.
        rateChangeObserver = NotificationCenter.default.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rateChanged() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                // Before the session is at its position the player's time is the old item's, or zero.
                guard let self, let session = self.live, session.stage == .running, time.isValid, time.isNumeric else { return }
                self.onEvent?(.engineTick(session.epoch, position: time.seconds))
            }
        }
    }

    /// A start that waits longer than the grace is a stall after all: asked again when the grace is over - by a task that does not hold the engine
    /// while it waits (an engine its owner has let go of must not be kept alive for three seconds), and again where it came early.
    private func watchTheGrace() {
        Task { @MainActor [weak self] in
            // (`self` is looked at one expression at a time: a strong reference held across the sleep would keep the engine alive.)
            while let remaining = self?.graceRemaining() {
                try? await Task.sleep(nanoseconds: UInt64((remaining + 0.05) * 1_000_000_000))
                if self?.reportTheGraceIfOver() == true { return }
            }
        }
    }

    /// `seconds`, cut to what the item can seek to (see `SeekTarget`).
    private func clamped(_ seconds: TimeInterval, in item: AVPlayerItem?) -> TimeInterval {
        guard let item else { return seconds }
        let ends = item.seekableTimeRanges.map(\.timeRangeValue).filter { $0.isValid && !$0.isEmpty }.map { CMTimeRangeGetEnd($0).seconds }.filter { $0.isFinite }
        let duration = item.duration
        return SeekTarget.clamped(seconds, seekableEnd: ends.max(), duration: duration.isNumeric ? duration.seconds : nil)
    }

    private func graceRemaining() -> TimeInterval? {
        stallWatch.graceRemaining(now: ProcessInfo.processInfo.systemUptime)
    }

    private func reportTheGraceIfOver() -> Bool {
        guard let stalled = stallWatch.graceIsOver(now: ProcessInfo.processInfo.systemUptime, seekInFlight: live?.seek != nil) else { return false }
        report(stalled)
        return true
    }

    private func rateChanged() {
        guard let session = live, session.stage == .running else { return }
        // (What the player is now, not what it was when the notification was posted: this runs a moment later.)
        let isPlaying = player.rate > 0
        guard isPlaying != expectsPlaying else { return }
        expectsPlaying = isPlaying
        onEvent?(isPlaying ? .play : .pause)
    }

    private func report(_ report: StallWatch.Report?) {
        guard let report, let session = live, session.stage == .running else { return }
        switch report {
        case .stalled: onEvent?(.engineStalled(session.epoch))
        case .recovered: onEvent?(.engineRecovered(session.epoch))
        }
    }

    private nonisolated static func reason(for error: Error?) -> String {
        guard let error = error as NSError? else { return "unknown failure" }
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    /// Option positions inside the audible and legible groups.
    ///
    /// - Audio: a number selects that option; a number the stream has no option for changes nothing (what the viewer had stays); `nil` is "no
    ///   choice" and hands the group back to AVFoundation - an explicit choice stays in force until that is said (AVPlayerItem.h,
    ///   `selectMediaOptionAutomatically(in:)`), so without it the state machine says "default" while the player plays the track the viewer chose.
    /// - Subtitles: a number selects that option (an out-of-range one changes nothing - it used to turn the subtitles off). `nil` is "off", and "off" said
    ///   to the group is a choice of its own: from then on AVFoundation no longer shows the forced subtitles it picks by itself (the lines of a film in a
    ///   language the viewer does not understand, in the language of the audio) nor lets them follow a change of the audio. So it is said only where it has
    ///   something to turn off - when a subtitle that is not a forced one is on (a plain start has none, and AVFoundation may have put one on because of
    ///   the machine's settings), and when the viewer is turning off one he chose (`after` had a subtitle), a forced one included.
    static let defaultApplier: SelectionApplier = { item, selection in await applyDefault(item, selection, after: nil) }

    /// - Parameter previous: the choice applied before this one in the session, if any.
    static func applyDefault(_ item: AVPlayerItem, _ selection: TrackSelection, after previous: TrackSelection?) async {
        let asset = item.asset
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            if let index = selection.audio {
                if group.options.indices.contains(index) { item.select(group.options[index], in: group) }
            } else {
                item.selectMediaOptionAutomatically(in: group)
            }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            if let index = selection.subtitle {
                if group.options.indices.contains(index) { item.select(group.options[index], in: group) }
            } else if group.allowsEmptySelection, let on = item.currentMediaSelection.selectedMediaOption(in: group),
                      previous?.subtitle != nil || !on.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
                item.select(nil, in: group)
            }
        }
    }
}
