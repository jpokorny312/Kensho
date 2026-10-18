import Foundation
import AVFoundation
import Kensho

/// Plays the instructions of a `PlaybackCoordinator` on an `AVPlayer`.
///
/// Every report it makes carries the epoch of the instruction that started
/// the item it is talking about, so the reducer can drop what a replaced
/// item says late.
@MainActor
public final class AVPlayerEngine: PlaybackEngine {
    public var onEvent: ((PlaybackEvent) -> Void)?
    public let player: AVPlayer

    /// Resolves what to hand AVPlayer for a source at a quality. Typically
    /// starts the PrismCore session (or builds the server URL) and returns
    /// the playlist address. Throwing reports a failure for that epoch.
    public typealias ItemProvider = @MainActor (MediaSource, QualityChoice?) async throws -> AVPlayerItem
    /// Applies the viewer's track choice to an item. The default maps the
    /// numbers to option positions inside AVFoundation's audible and legible
    /// groups; an app that maps stream indices differently passes its own.
    public typealias SelectionApplier = @MainActor (AVPlayerItem, TrackSelection) async -> Void

    private let provider: ItemProvider
    private let applier: SelectionApplier
    private var epoch = Epoch.initial
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?

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
            start(epoch: epoch, source: source, quality: quality, startAt: startAt, selection: selection, isSwap: false)

        case let .swap(epoch, quality, startAt, selection):
            // A swap re-resolves the same source at another quality.
            start(epoch: epoch, source: currentSource, quality: quality, startAt: startAt, selection: selection, isSwap: true)

        case let .play(epoch):
            guard epoch == self.epoch else { return }
            player.play()

        case let .pause(epoch):
            guard epoch == self.epoch else { return }
            player.pause()

        case let .seek(epoch, token, target):
            guard epoch == self.epoch else { return }
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
            guard epoch == self.epoch, let item = player.currentItem else { return }
            Task { await applier(item, selection) }

        case let .stop(epoch):
            _ = epoch
            loadTask?.cancel()
            statusObservation = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private var currentSource = MediaSource(id: "", range: .sdr)

    private func start(
        epoch: Epoch, source: MediaSource, quality: QualityChoice?,
        startAt: TimeInterval, selection: TrackSelection, isSwap: Bool
    ) {
        self.epoch = epoch
        currentSource = source
        loadTask?.cancel()
        statusObservation = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await provider(source, quality)
                // Replaced while resolving: a newer instruction owns the player.
                guard !Task.isCancelled, self.epoch == epoch else { return }
                self.observe(item: item, epoch: epoch, startAt: startAt, selection: selection, isSwap: isSwap)
                self.player.replaceCurrentItem(with: item)
            } catch {
                guard !Task.isCancelled, self.epoch == epoch else { return }
                self.onEvent?(.engineFailed(epoch, reason: "\(error)"))
            }
        }
    }

    private func observe(item: AVPlayerItem, epoch: Epoch, startAt: TimeInterval, selection: TrackSelection, isSwap: Bool) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.epoch == epoch else { return }
                switch item.status {
                case .readyToPlay:
                    self.statusObservation = nil
                    if startAt > 0 {
                        let time = CMTime(seconds: startAt, preferredTimescale: 600)
                        await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    await self.applier(item, selection)
                    guard self.epoch == epoch else { return }
                    self.onEvent?(isSwap ? .swapFinished(epoch) : .engineReady(epoch))
                case .failed:
                    self.statusObservation = nil
                    self.onEvent?(.engineFailed(epoch, reason: item.error.map { "\($0)" } ?? "item failed"))
                default:
                    break
                }
            }
        }
    }

    private func observePlayer() {
        // Waiting while play was requested is a stall; playing again is
        // recovery. The reducer ignores both outside the phases they apply to.
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                switch player.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate: self.onEvent?(.engineStalled(self.epoch))
                case .playing: self.onEvent?(.engineRecovered(self.epoch))
                default: break
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, time.isValid, time.isNumeric else { return }
                self.onEvent?(.engineTick(self.epoch, position: time.seconds))
            }
        }
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
