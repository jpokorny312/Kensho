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
/// With `Options.prebuffer` the second player is more than a proof that the stream loads: it loads the stream ahead of the running player, jumps to
/// where the running one will be, and **becomes `player`** (`onPlayerChange`) at the moment the old one reaches that place - one stops where the other
/// begins, with nothing to fetch and nothing to decode in between (`PrebufferedPlayer`). Without it the replacement is a copy of the prepared item on the
/// running player, which asks for the media again and waits to minimize stalls: the picture stands for the seconds that takes.
///
/// What the engine reports as a stall is playback that was running and ran
/// dry (see `StallWatch`), not the wait for the first data after `play()`, a
/// seek or a swap: AVPlayer shows `waitingToPlayAtSpecifiedRate` for every one
/// of those, and a quality policy that took each for a weak link would step
/// down for nothing.
@MainActor
public final class AVPlayerEngine: PlaybackEngine {
    public var onEvent: ((PlaybackEvent) -> Void)?
    /// The player that plays. It is the one the engine was made with until a prebuffered replacement takes over (`Options.prebuffer`): then it is
    /// the replacement's, and `onPlayerChange` says so.
    public private(set) var player: AVPlayer
    /// A prebuffered replacement took over: `new` is `player` now, `old` is let go of a moment after this returns. Whoever shows the picture, or holds the
    /// player for anything else (picture in picture, the lock screen, a time observer of its own), follows here - in the same turn, so that the layer
    /// shows the new player's picture when the old one's has ended. **Without a handler the engine makes no prebuffered hand-off** (the owner would go on
    /// looking at a player that has stopped): a replacement is then a copy on the running player, as without the option.
    public var onPlayerChange: ((_ new: AVPlayer, _ old: AVPlayer) -> Void)?
    /// A layer the replacement's player is shown on while it waits (`Options.Prebuffer.waitsForFirstFrame`): a player that has no layer decodes no
    /// picture, and the first frame after the hand-off would be a decoder starting. Whoever owns a view puts the layer in it, anywhere (a point in the
    /// corner will do) and *under* the layer of the picture; the engine puts the replacement's player on it and takes it off again.
    public let stagingLayer = AVPlayerLayer()

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
            /// Where AVPlayer lands most cheaply, without the cost of decoding up to the exact position. Measured on HLS streams, with a picture that has a
            /// keyframe every two seconds (`AVPlayerEngineHLSPictureTests`): on the target where the part it is in has been loaded already (not always, under load), at the **start of
            /// its segment** where it has not - not at a keyframe inside the segment (15.6 s lands at 12.005 s in segments of 6 s that have keyframes at 14.0
            /// and 16.0) - and no different from the plain `seek(to:)` that the old engine of the car used. `seekFinished` says that the jump landed, not
            /// where: the state machine keeps the target until the next tick of the player says otherwise.
            case cheapest
        }

        /// The item is told where to begin before it is on the player: a session whose start position is more than zero gets
        /// `AVPlayerItem.seek(to:toleranceBefore:toleranceAfter:)` with no tolerance before `replaceCurrentItem` - a load at a position, a `reload`, and the item
        /// that takes over from another at the position the player was at. Without it the item begins at 0, and AVPlayer fetches the first segments of the
        /// stream (picture and sound) and shows its first frame before the jump the engine makes when the item is ready arrives. Measured on an HLS stream of 60 s
        /// with a start at 33 s (`AVPlayerEngineHLSPictureTests`, `Docs/Zusammenfuehrung.md`): without the option some of the segments 0 to 5 are asked for before the ones
        /// from 16 on, and the frames seen are 0 and 792; with it the first segment asked for is 16 and the only frame is 792. A source that makes a segment when it is
        /// asked for pays for each of those (PrismCore: not measured).
        ///
        /// What stays: the jump after `readyToPlay`, exact, and `engineReady` (`swapFinished`) only when it has landed. The position is not cut to what the item can
        /// seek to (`SeekTarget`) - an item that is not loaded has no seekable ranges - so one past the end goes to AVPlayer as it is (it takes the item to the start of
        /// its last segment), and the jump after `readyToPlay` puts the session at the end.
        ///
        /// A provider that tells the item itself (`item.seek` before it returns it) is told over: the engine's seek is the later one and replaces the provider's, with no
        /// tolerance, and the item would be at the exact position after `readyToPlay` anyway. A session that `startsPlayingAtOnce` is never told: its start position is
        /// the provider's. The time of the item is taken to be the time of the film, as the jump after `readyToPlay` takes it already.
        public var tellsItemWhereToBegin: Bool

        /// A replacement (a quality change) is made ready on a player of its own, loaded ahead of the running one, and takes over *as the player*, at the
        /// moment the running one reaches the place it waits at - the picture does not stand (measured on an HLS stream with a picture, a replacement that
        /// answers 0.6 s late: 2.7 s of standing picture with the copy, 0.05 s - one frame - with this). nil: the replacement is a copy of the prepared item on
        /// the running player. It needs an owner that follows `onPlayerChange`, no external playback (AirPlay, the car: their route is the running player's)
        /// and a running player that plays; in any other case the engine does what it does without the option.
        public var prebuffer: Prebuffer?

        public struct Prebuffer: Equatable, Sendable {
            /// Seconds that must be loaded from the place the replacement waits at before it is ready (and the reducer is told so).
            public var bufferSeconds: TimeInterval
            /// How far ahead of the running player the replacement waits: it is ready for the place where the running player will be when the hand-off
            /// comes, which is a little ahead of where it is when the replacement is asked for. Less when the running player has little buffered.
            public var lead: TimeInterval
            /// A replacement that is not ready after this long is given up (`swapFailed`: the running player goes on).
            public var timeout: TimeInterval
            /// Wait for the first picture to be ready for display on `stagingLayer` (put in a view by the owner) before the replacement counts as ready.
            public var waitsForFirstFrame: Bool

            public init(bufferSeconds: TimeInterval = 6, lead: TimeInterval = 3, timeout: TimeInterval = 40, waitsForFirstFrame: Bool = false) {
                self.bufferSeconds = bufferSeconds
                self.lead = lead
                self.timeout = timeout
                self.waitsForFirstFrame = waitsForFirstFrame
            }
        }

        public init(startsPlayingAtOnce: Bool = false, jumps: Jumps = .exact, tellsItemWhereToBegin: Bool = false, prebuffer: Prebuffer? = nil) {
            self.startsPlayingAtOnce = startsPlayingAtOnce
            self.jumps = jumps
            self.tellsItemWhereToBegin = tellsItemWhereToBegin
            self.prebuffer = prebuffer
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
            /// A prebuffered replacement has been told to take over: the running player plays on until the moment of the hand-off.
            case handingOff
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
        /// The replacement's own player, with its item loaded ahead of the running one (`Options.prebuffer`).
        var prebuffered: PrebufferedPlayer?
        var prebufferTask: Task<Void, Never>?

        init(epoch: Epoch, atPosition: @escaping (Epoch) -> PlaybackEvent) {
            self.epoch = epoch
            self.atPosition = atPosition
        }

        /// Ends the session's work. A prebuffered player is not let go of here: whether it is the player now or is thrown away is the engine's to say.
        func end() {
            resolveTask?.cancel()
            startTask?.cancel()
            selectionTask?.cancel()
            prebufferTask?.cancel()
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
    /// The player the observers above are on.
    private weak var observedPlayer: AVPlayer?

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
        if let timeObserver { observedPlayer?.removeTimeObserver(timeObserver) }
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
            if let prebuffered = session.prebuffered, onPlayerChange != nil, !player.isExternalPlaybackActive {
                // The replacement has its own player, loaded ahead of this one: it takes over as the player when this one gets to the place it waits at.
                replacement = nil
                endLive()
                live = session
                session.selection = selection
                handOff(session, prebuffered: prebuffered)
                return
            }
            // Where the player is, not where the last tick said: the reducer's position is up to half a second old.
            let measured = player.currentTime().seconds
            replacement = nil
            endLive()
            live = session
            session.startAt = measured.isFinite && abs(measured - at) < 5 ? measured : at
            session.selection = selection
            // (A prebuffered replacement that cannot be handed over - nobody follows the change of player, or the picture is on a route that belongs to this
            // one - is a prepared item like the others: its player gives the item up, and a copy goes on the running player.)
            discardPrebuffer(of: session)
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
            // (Not during a hand-off - it sets the new player going itself - and not for a player that goes: a start on the host clock is a rate of 1
            // that has not begun, and `play()` would begin it early.)
            if session.stage != .handingOff, player.rate == 0 { player.play() }

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
                if item === self.player.currentItem || (self.isStagingCreated && item === self.staging.currentItem) || item === self.replacement?.prebuffered?.item {
                    self.fail(session, reason: "the provider returned an item that is on a player already")
                    return
                }
                if session === self.live {
                    self.attachToPlayer(session, item: item)
                } else if self.options.prebuffer != nil {
                    self.attachToPrebuffer(session, item: item)
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
        watch(session, item: item)
        let setsGoing = session.startsAtOnce && !session.held
        expectsPlaying = setsGoing
        player.pause()
        if options.tellsItemWhereToBegin, !session.startsAtOnce, session.startAt.isFinite, session.startAt > 0 {
            // (No completion handler: `start()` jumps again when the item is ready, and says so when it has landed. The position is not cut to the
            // seekable ranges - an item that is not loaded has none; see `Options.tellsItemWhereToBegin`.)
            item.seek(to: CMTime(seconds: session.startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
        player.replaceCurrentItem(with: item)
        if setsGoing { player.play() }
    }

    /// What the live session's item is watched for: its status (an item that is ready can still fail) and the end that is a failure.
    private func watch(_ session: Session, item: AVPlayerItem) {
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
    }

    private func attachToStaging(_ session: Session, item: AVPlayerItem) {
        session.stage = .loading
        session.item = item
        observeStatus(of: session, item: item)
        staging.replaceCurrentItem(with: item)
    }

    // MARK: - A replacement with a player of its own (`Options.prebuffer`)

    /// Makes the replacement ready on a player of its own: loaded ahead of the running player, positioned, primed (`PrebufferedPlayer`). The reducer is told
    /// `swapPrepared` when it can take over without a wait, not when the stream merely loads.
    private func attachToPrebuffer(_ session: Session, item: AVPlayerItem) {
        guard let settings = options.prebuffer else { return }
        session.stage = .loading
        session.item = item
        let prebuffered = PrebufferedPlayer.beside(player, item: item, startAt: session.startAt, settings: settings)
        session.prebuffered = prebuffered
        if settings.waitsForFirstFrame { prebuffered.prime(on: stagingLayer) }
        let began = ProcessInfo.processInfo.systemUptime
        session.prebufferTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try await prebuffered.prepare()
                guard !Task.isCancelled, session === self.replacement else { return }
                // The viewer's tracks are carried out while the replacement waits, not after it has taken over: another audio rendition is a fetch of its own.
                await self.applier(item, session.selection, session.applied)
                session.applied = session.selection
                guard !Task.isCancelled, session === self.replacement else { return }
                session.stage = .prepared
                self.log.log(String(format: "replacement %d ready after %.1f s, waiting at %.1f s with %.1f s loaded", session.epoch.rawValue,
                                    ProcessInfo.processInfo.systemUptime - began, prebuffered.position, prebuffered.bufferedAhead(from: prebuffered.position)), tag: "kensho")
                self.onEvent?(.swapPrepared(session.epoch))
            } catch {
                guard !Task.isCancelled, session === self.replacement else { return }
                self.log.log("replacement \(session.epoch.rawValue) could not be made ready: \(error)", tag: "kensho")
                self.fail(session, reason: (error as? PrebufferedPlayer.Failure).map { "the replacement could not be made ready: \($0)" } ?? Self.reason(for: error))
            }
        }
    }

    /// The end of the loaded part of `item` that contains `time`.
    private func loadedEnd(of item: AVPlayerItem?, containing time: TimeInterval) -> TimeInterval? {
        PrebufferedPlayer.loadedEnd(of: item, containing: time)
    }

    /// The prebuffered replacement takes over (`PrebufferedPlayer.handOver`): the running player plays on until the place it is handed over at, the
    /// replacement - jumped there and primed - is set going on the host clock at the moment the running one gets there, and the running item ends there.
    /// Then `player` is the replacement's, `onPlayerChange` says so, and the reducer is told `swapFinished`.
    ///
    /// (The running player is listened to no more from here on: its rate goes to 0 at the end of its part, and that is nobody's pause.) A hand-off that
    /// cannot be made ends as a copy of the prepared item on the running player, the way a replacement is made without the option.
    private func handOff(_ session: Session, prebuffered: PrebufferedPlayer) {
        let old = player
        let oldItem = old.currentItem
        unobservePlayer()
        session.stage = .handingOff
        session.startTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            let outcome = await prebuffered.handOver(
                from: old,
                isHeld: { [weak session] in session?.held ?? true },
                isCurrent: { [weak self, weak session] in
                    guard let self, let session else { return false }
                    return session === self.live && session.stage == .handingOff
                },
                log: { [weak self, weak session] line in self?.log.log("\(line) (replacement \(session?.epoch.rawValue ?? 0))", tag: "kensho") },
                flip: { [weak self, weak session] playing in
                    guard let self, let session else { return }
                    self.completeFlip(session, prebuffered: prebuffered, old: old, playing: playing)
                }
            )
            guard !Task.isCancelled, session === self.live, session.stage == .handingOff else { return }
            if case .failed = outcome { self.fallBackToCopy(session, prebuffered: prebuffered, old: old, oldItem: oldItem) }
        }
    }

    /// The replacement's player is `player` from here on.
    private func completeFlip(_ session: Session, prebuffered: PrebufferedPlayer, old: AVPlayer, playing: Bool) {
        let new = prebuffered.player
        // What the owner had set on the player carries over (the replacement was silent while it waited).
        new.isMuted = old.isMuted
        new.volume = old.volume
        new.allowsExternalPlayback = old.allowsExternalPlayback
        new.actionAtItemEnd = old.actionAtItemEnd
        new.defaultRate = old.defaultRate
        let waitsToMinimizeStalls = old.automaticallyWaitsToMinimizeStalling
        session.prebuffered = nil
        session.item = prebuffered.item
        player = new
        expectsPlaying = playing
        watch(session, item: prebuffered.item)
        observePlayer()
        // (The status of the new player is the one the stall watch goes on from: it was not listened to while it waited.)
        _ = stallWatch.observe(new.timeControlStatus, seekInFlight: false, now: ProcessInfo.processInfo.systemUptime)
        session.stage = .running
        onPlayerChange?(new, old)
        prebuffered.unprime()                                    // (after the owner has put the new player on its own layer)
        onEvent?(session.atPosition(session.epoch))
        // The hand-over has been made when the old player is let go of and the new one waits for the clock again - a moment later, so that neither the
        // layer nor the start on the host clock is disturbed.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            old.pause()
            old.currentItem?.forwardPlaybackEndTime = .invalid
            old.replaceCurrentItem(with: nil)
            guard let self, self.player === new else { return }
            new.automaticallyWaitsToMinimizeStalling = waitsToMinimizeStalls
        }
        // The choice of tracks the viewer made after the replacement was asked for.
        if session.applied != session.selection {
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, session === self.live, let item = session.item else { return }
                self.stallWatch.trackChanged(now: ProcessInfo.processInfo.systemUptime)
                await self.applier(item, session.selection, session.applied)
                session.applied = session.selection
                self.stallWatch.trackChanged(now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    /// A hand-off that could not be made: the replacement's player gives its item up, and a copy goes on the running player, which is listened to again.
    private func fallBackToCopy(_ session: Session, prebuffered: PrebufferedPlayer, old: AVPlayer, oldItem: AVPlayerItem?) {
        log.log("hand-off of \(session.epoch.rawValue) could not be made; the replacement goes on the running player as a copy", tag: "kensho")
        let item = prebuffered.item
        let measured = old.currentTime().seconds
        oldItem?.forwardPlaybackEndTime = .invalid
        discardPrebuffer(of: session)
        session.startAt = measured.isFinite ? measured : session.startAt
        observePlayer()
        let copy = (item.copy() as? AVPlayerItem) ?? AVPlayerItem(asset: item.asset)
        attachToPlayer(session, item: copy)
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
        guard let session = live else { return }
        session.end()
        live = nil
        discardPrebuffer(of: session)
    }

    private func endReplacement() {
        guard let session = replacement else { return }
        replacement = nil
        session.end()
        discardPrebuffer(of: session)
        if session.item != nil, session.prebuffered == nil, isStagingCreated { staging.replaceCurrentItem(with: nil) }
    }

    /// Lets go of the replacement's own player, if it still has one (a replacement that took over has given it up: it is `player`).
    private func discardPrebuffer(of session: Session) {
        guard let prebuffered = session.prebuffered else { return }
        session.prebuffered = nil
        prebuffered.cancel()
        if session.stage == .handingOff {
            // The hand-off ended on the way: the player that plays is still this one, and it is listened to again.
            player.currentItem?.forwardPlaybackEndTime = .invalid
            observePlayer()
        }
    }

    // MARK: - What the player says

    /// Stops listening to the player (the one that is handed over: its rate goes to 0 at the end of its part, and that is not the viewer's pause).
    private func unobservePlayer() {
        rateObservation = nil
        if let rateChangeObserver { NotificationCenter.default.removeObserver(rateChangeObserver) }
        rateChangeObserver = nil
        if let timeObserver { observedPlayer?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observedPlayer = nil
    }

    private func observePlayer() {
        guard observedPlayer !== player else { return }
        observedPlayer = player
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
