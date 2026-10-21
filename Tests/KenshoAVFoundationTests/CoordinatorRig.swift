import Foundation
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// The reducer, the coordinator and an `AVPlayerEngine` on a real `AVPlayer` (muted): `CoordinatorOnAVPlayerTests` plays generated files with it,
/// `CoordinatorOnHLSTests` a stream from the loopback.
@MainActor
final class Rig {
    let directory: URL
    let player = AVPlayer()
    private(set) var engine: AVPlayerEngine!
    private(set) var coordinator: PlaybackCoordinator!
    private(set) var phases: [Phase] = []
    private(set) var effects: [PlaybackEffect] = []
    private(set) var applied: [TrackSelection] = []
    /// The clock of the quality cooldown.
    var now: TimeInterval = 1_000
    var files: [String: URL] = [:]
    /// What the test needs for as long as the rig lives and holds nothing itself: a server the URLs of `files` point to.
    var retained: [AnyObject] = []
    /// Called with every item the provider makes, before it is on the player. A test with a picture puts its `PictureProbe` on it here: a player with
    /// nothing that takes its frames does not wait for the picture (`HLSFixtureTests`), and would play on past a part of it that is not there.
    var itemMade: ((AVPlayerItem) -> Void)?

    /// - Parameters:
    ///   - makesFiles: write the two files `film` and `film-lo` (40 s of silence each); a test that sets `files` itself, to streams, says no.
    ///   - recordsSelections: the applier only writes the choices down (`applied`); false leaves it to the engine's default applier, which chooses the
    ///     options of the item's real media selection groups.
    init(options: AVPlayerEngine.Options = AVPlayerEngine.Options(), makesFiles: Bool = true, recordsSelections: Bool = true, log: KenshoLog = .silent) throws {
        directory = try TestMedia.makeDirectory()
        if makesFiles {
            files["film"] = try TestMedia.silentAudio(seconds: 40, in: directory, name: "film")
            files["film-lo"] = try TestMedia.silentAudio(seconds: 40, in: directory, name: "film-lo")
        }
        player.isMuted = true
        engine = AVPlayerEngine(
            player: player,
            provider: { [weak self] request in
                let source = request.source, quality = request.quality
                guard let self, let url = self.files[quality.map { "\(source.id)-\($0.id)" } ?? source.id] ?? self.files[source.id] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let item = AVPlayerItem(url: url)
                self.itemMade?(item)
                return item
            },
            applier: recordsSelections ? { [weak self] _, selection in self?.applied.append(selection) } : nil,
            options: options,
            log: log
        )
        coordinator = PlaybackCoordinator(engine: engine, clock: { [weak self] in self?.now ?? 0 })
        // The phases the film went through: a state change that only moved the position is not one.
        coordinator.onStateChange = { [weak self] in if let self, self.phases.last != $0.phase { self.phases.append($0.phase) } }
        coordinator.onTransition = { [weak self] _, _, effects in self?.effects.append(contentsOf: effects) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var state: PlaybackState { coordinator.state }
    var playingFile: String? { (player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent }
    var playingURL: URL? { (player.currentItem?.asset as? AVURLAsset)?.url }

    @discardableResult
    func wait(timeout: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Where the viewer sees the playback: the state's position, fed by the engine's ticks.
    func waitUntilPlayingPast(_ position: TimeInterval) async -> Bool {
        await wait { self.state.phase == .playing && self.state.position > position }
    }
}
