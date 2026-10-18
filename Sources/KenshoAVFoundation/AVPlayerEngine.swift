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
/// `player` plays on, and only `commitSwap` moves it over.
@MainActor
public final class AVPlayerEngine: PlaybackEngine {
    public var onEvent: ((PlaybackEvent) -> Void)?
    public let player: AVPlayer

    /// Resolves what to hand AVPlayer for a source at a quality. Typically
    /// starts the PrismCore session (or builds the server URL) and returns
    /// the item for the playlist address. Throwing reports a failure for that
    /// epoch.
    public typealias ItemProvider = @MainActor (MediaSource, QualityChoice?) async throws -> AVPlayerItem
    /// Applies the viewer's track choice to an item. The default maps the
    /// numbers to option positions inside AVFoundation's audible and legible
    /// groups; an app that maps stream indices differently passes its own.
    public typealias SelectionApplier = @MainActor (AVPlayerItem, TrackSelection) async -> Void

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

        let epoch: Epoch
        /// What the reducer is told when the session is at its position: a
        /// fresh load is `engineReady`, a replacement that took over is
        /// `swapFinished`.
        let atPosition: (Epoch) -> PlaybackEvent
        var stage: Stage = .resolving
        var item: AVPlayerItem?
        var startAt: TimeInterval = 0
        var selection = TrackSelection()
        var statusObservation: NSKeyValueObservation?
        var failureObserver: NSObjectProtocol?
        var resolveTask: Task<Void, Never>?
        var startTask: Task<Void, Never>?

        init(epoch: Epoch, atPosition: @escaping (Epoch) -> PlaybackEvent) {
            self.epoch = epoch
            self.atPosition = atPosition
        }

        func end() {
            resolveTask?.cancel()
            startTask?.cancel()
            statusObservation = nil
            if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
            failureObserver = nil
        }
    }

    private let provider: ItemProvider
    private let applier: SelectionApplier
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
        let staging = AVPlayer()
        staging.isMuted = true
        staging.allowsExternalPlayback = false
        return staging
    }()
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    public init(
        player: AVPlayer = AVPlayer(),
        provider: @escaping ItemProvider,
        applier: SelectionApplier? = nil
    ) {
        self.player = player
        self.provider = provider
        self.applier = applier ?? AVPlayerEngine.defaultApplier
        observePlayer()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    public func perform(_ effect: PlaybackEffect) {
        switch effect {
        case let .load(epoch, source, startAt, selection, quality):
            endReplacement()
            endLive()
            self.source = source
            let session = Session(epoch: epoch, atPosition: { .engineReady($0) })
            session.startAt = startAt
            session.selection = selection
            live = session
            resolve(session, source: source, quality: quality) { [unowned self] item in
                self.attachToPlayer(session, item: item)
            }

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
            resolve(session, source: source, quality: quality) { [unowned self] item in
                session.stage = .loading
                session.item = item
                self.observeStatus(of: session, item: item)
                self.staging.replaceCurrentItem(with: item)
            }

        case let .commitSwap(epoch, replacing, at, selection):
            guard let session = replacement, session.epoch == epoch, session.stage == .prepared, let item = session.item else {
                onEvent?(.engineFailed(epoch, reason: "no prepared session \(epoch.rawValue) to take over from \(replacing.rawValue)"))
                return
            }
            replacement = nil
            endLive()
            live = session
            session.startAt = at
            session.selection = selection
            staging.replaceCurrentItem(with: nil)
            attachToPlayer(session, item: item)

        case let .discardSwap(epoch):
            guard replacement?.epoch == epoch else { return }
            endReplacement()

        case let .play(epoch):
            guard live?.epoch == epoch else { return }
            player.play()

        case let .pause(epoch):
            guard live?.epoch == epoch else { return }
            player.pause()

        case let .seek(epoch, token, target):
            guard live?.epoch == epoch else { return }
            let time = CMTime(seconds: target, preferredTimescale: 600)
            // Zero tolerance: a keyframe-snapped seek lands a few seconds
            // off the target and the picture jumps back after it.
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                // A seek superseded by a newer one completes with `false`.
                // The token already drops it; ignoring it here avoids
                // reporting a position the player never reached.
                guard finished else { return }
                Task { @MainActor in self?.onEvent?(.seekFinished(epoch, token)) }
            }

        case let .applySelection(epoch, selection):
            guard let session = live, session.epoch == epoch, let item = session.item else { return }
            Task { await applier(item, selection) }

        case .stop:
            endReplacement()
            endLive()
            source = nil
        }
    }

    // MARK: - Making a session

    /// Asks the provider for the session's item. A newer instruction ends the
    /// session; what the provider returns after that is dropped.
    private func resolve(_ session: Session, source: MediaSource, quality: QualityChoice?, then attach: @escaping (AVPlayerItem) -> Void) {
        session.resolveTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let item = try await self.provider(source, quality)
                guard !Task.isCancelled, self.isCurrent(session) else { return }
                attach(item)
            } catch {
                guard !Task.isCancelled, self.isCurrent(session) else { return }
                self.fail(session, reason: Self.reason(for: error))
            }
        }
    }

    private func isCurrent(_ session: Session) -> Bool {
        session === live || session === replacement
    }

    /// Puts the item on `player`, paused: a session starts where it is told to
    /// and plays when the reducer says so.
    private func attachToPlayer(_ session: Session, item: AVPlayerItem) {
        session.stage = .starting
        session.item = item
        observeStatus(of: session, item: item)
        session.failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self, weak session] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let reason = Self.reason(for: error)
            Task { @MainActor in
                guard let self, let session, session === self.live else { return }
                self.fail(session, reason: reason)
            }
        }
        player.pause()
        player.replaceCurrentItem(with: item)
    }

    private func observeStatus(of session: Session, item: AVPlayerItem) {
        // `.initial`: an item that is ready already (a prepared one that was
        // moved to another player) is not announced by a change.
        session.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak session] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in
                guard let self, let session, self.isCurrent(session) else { return }
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
            guard let item = session.item else { return }
            session.startTask = Task { [weak self, weak session] in
                guard let self, let session else { return }
                if session.startAt > 0 {
                    let time = CMTime(seconds: session.startAt, preferredTimescale: 600)
                    await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                await self.applier(item, session.selection)
                guard !Task.isCancelled, session === self.live else { return }
                session.stage = .running
                self.onEvent?(session.atPosition(session.epoch))
            }
        case (.failed, _):
            fail(session, reason: Self.reason(for: error))
        default:
            break
        }
    }

    /// A session that cannot go on: a replacement is given up (the live one
    /// plays on), the live one is reported to the reducer.
    private func fail(_ session: Session, reason: String) {
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
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func endReplacement() {
        guard let session = replacement else { return }
        replacement = nil
        session.end()
        if session.item != nil { staging.replaceCurrentItem(with: nil) }
    }

    // MARK: - What the player says

    private func observePlayer() {
        // Waiting while play was requested is a stall; playing again is
        // recovery. The reducer ignores both outside the phases they apply to.
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self, let epoch = self.live?.epoch else { return }
                switch status {
                case .waitingToPlayAtSpecifiedRate: self.onEvent?(.engineStalled(epoch))
                case .playing: self.onEvent?(.engineRecovered(epoch))
                default: break
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, let epoch = self.live?.epoch, time.isValid, time.isNumeric else { return }
                self.onEvent?(.engineTick(epoch, position: time.seconds))
            }
        }
    }

    private nonisolated static func reason(for error: Error?) -> String {
        guard let error = error as NSError? else { return "unknown failure" }
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    /// Option positions inside the audible and legible groups; `nil` audio
    /// keeps AVFoundation's default, `nil` subtitle turns subtitles off.
    private static let defaultApplier: SelectionApplier = { item, selection in
        guard let asset = item.asset as? AVURLAsset else { return }
        if let index = selection.audio,
           let group = try? await asset.loadMediaSelectionGroup(for: .audible),
           group.options.indices.contains(index) {
            item.select(group.options[index], in: group)
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            if let index = selection.subtitle, group.options.indices.contains(index) {
                item.select(group.options[index], in: group)
            } else {
                item.select(nil, in: group)
            }
        }
    }
}
