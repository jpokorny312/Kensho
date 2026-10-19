import Foundation
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// An `AVPlayerEngine` on a real `AVPlayer` with the events it reports written down, for the tests that drive the engine by hand
/// (`AVPlayerEngineTests` on files, `AVPlayerEngineHLSTests` on a stream from the loopback).
@MainActor
final class EngineHarness {
    enum Failure: Error { case noItem(String) }

    let directory: URL
    let player = AVPlayer()
    private(set) var engine: AVPlayerEngine!
    private(set) var events: [PlaybackEvent] = []
    private(set) var provided: [(MediaSource, QualityChoice?)] = []
    /// What the provider was asked, whole.
    private(set) var requests: [AVPlayerEngine.ItemRequest] = []
    /// Files by name; the default provider maps `source.id` (or `source.id-quality.id`) to one.
    var files: [String: URL] = [:]
    /// What the provider does, per call. Replaced by tests that need a slow or failing one.
    var make: ((MediaSource, QualityChoice?) async throws -> AVPlayerItem)?
    /// What the test needs for as long as the engine lives and holds nothing itself: a server that the items' URLs point to is gone with its last reference
    /// (`let (h, _) = ...` would drop it at once).
    var retained: [AnyObject] = []

    init(applier: AVPlayerEngine.SelectionApplier? = nil, options: AVPlayerEngine.Options = AVPlayerEngine.Options()) throws {
        directory = try TestMedia.makeDirectory()
        player.isMuted = true
        engine = AVPlayerEngine(
            player: player,
            provider: { [weak self] request in
                // (A session the test has left may still ask: nothing is there to answer.)
                guard let self else { throw Failure.noItem("the test is over") }
                let source = request.source, quality = request.quality
                self.provided.append((source, quality))
                self.requests.append(request)
                if let make = self.make { return try await make(source, quality) }
                let key = quality.map { "\(source.id)-\($0.id)" } ?? source.id
                guard let url = self.files[key] ?? self.files[source.id] else { throw Failure.noItem(key) }
                return AVPlayerItem(url: url)
            },
            applier: applier,
            options: options
        )
        engine.onEvent = { [weak self] in self?.events.append($0) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func addFile(_ name: String, seconds: Double) throws {
        files[name] = try TestMedia.silentAudio(seconds: seconds, in: directory, name: name)
    }

    /// Polls until `condition` holds; the run loop keeps turning while it waits.
    @discardableResult
    func wait(timeout: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @discardableResult
    func waitFor(_ event: PlaybackEvent, timeout: TimeInterval = 10) async -> Bool {
        await wait(timeout: timeout) { self.events.contains(event) }
    }

    func clearEvents() { events.removeAll() }

    func stalls(of epoch: Epoch) -> Int { events.filter { $0 == .engineStalled(epoch) }.count }

    func ticks(of epoch: Epoch) -> [TimeInterval] {
        events.compactMap { if case let .engineTick(e, position) = $0, e == epoch { return position } else { return nil } }
    }

    /// The last position the engine reported for the epoch.
    func lastTick(of epoch: Epoch) -> TimeInterval? { ticks(of: epoch).last }
}
