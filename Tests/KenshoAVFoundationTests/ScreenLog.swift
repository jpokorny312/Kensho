import Foundation
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// What the screen shows, as a time line of frame numbers (`PictureCode`): every five milliseconds the item that is on the player that is asked for - which
/// may change from one moment to the next, as it does when a replacement takes over *as the player* - is asked for the frame it has ready.
///
/// A swap that is made well leaves no hole in this line; a swap that is made badly leaves one as long as the picture stood. (The clock of the player
/// cannot say that: an item that is replaced has a position of its own, which jumps. And a test that polls a probe when it likes misses what happened
/// between two polls.)
@MainActor
final class ScreenLog {
    private let player: () -> AVPlayer
    private var probes: [ObjectIdentifier: PictureProbe] = [:]
    private(set) var frames: [(t: Double, frame: Int)] = []
    private var timer: Timer?

    init(player: @escaping () -> AVPlayer) {
        self.player = player
        timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    deinit { timer?.invalidate() }

    /// A probe that was put on the item before it was on a player (it holds the frames from the start).
    func register(_ probe: PictureProbe, for item: AVPlayerItem) { probes[ObjectIdentifier(item)] = probe }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let item = player().currentItem else { return }
        let id = ObjectIdentifier(item)
        let probe: PictureProbe
        if let known = probes[id] {
            probe = known
        } else {
            probe = PictureProbe(item: item)
            probes[id] = probe
        }
        let before = probe.seen.count
        probe.poll()
        if probe.seen.count > before, let frame = probe.latest { frames.append((ProcessInfo.processInfo.systemUptime, frame)) }
    }

    /// The longest time the picture stood between two frames that continue the film (a frame that goes back - the opening frame of an item that was
    /// not told where to begin - is not one), from `start` on; `at` is when it began, counted from `start`.
    func freeze(after start: Double) -> (seconds: Double, at: Double) {
        var last: (t: Double, frame: Int)?
        var best = (seconds: 0.0, at: 0.0)
        for entry in frames where entry.t >= start {
            guard let previous = last else {
                last = entry
                continue
            }
            guard entry.frame > previous.frame else { continue }
            if entry.t - previous.t > best.seconds { best = (entry.t - previous.t, previous.t - start) }
            last = entry
        }
        return best
    }

    /// Frames that were shown twice in a row after each other going back, or skipped by more than `slack` frames: the film does not go on from where it was.
    func discontinuities(after start: Double, slack: Int = 6) -> [(from: Int, to: Int)] {
        var result: [(Int, Int)] = []
        var last: Int?
        for entry in frames where entry.t >= start {
            if let last, entry.frame < last || entry.frame > last + slack { result.append((last, entry.frame)) }
            last = entry.frame
        }
        return result
    }
}
