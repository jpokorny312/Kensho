import XCTest
import AVFoundation
@testable import Kensho
@testable import KenshoAVFoundation

/// The default applier and the forced subtitles of a stream (`HLSFixture.start(forcedSubtitles:)`): renditions with FORCED=YES are what a film has for the
/// lines the viewer would not understand, and AVFoundation shows the one in the language of the audio by itself - as long as nobody has chosen a subtitle
/// ("off" said to the group is a choice, and it ends that for good). The stream has four subtitle options, in the order of its master:
/// 0 English, 1 German, 2 English forced, 3 German forced; audio 0 is English (the default), audio 1 German.
@MainActor
final class AVPlayerEngineForcedSubtitleTests: XCTestCase {
    private let film = MediaSource(id: "film", range: .sdr)

    private func rig() async throws -> (h: EngineHarness, hls: HLSFixture) {
        let hls = try await HLSFixture.start(seconds: 20, forcedSubtitles: ["en", "de"])
        let h = try EngineHarness()
        h.files["film"] = hls.masterURL()
        h.retained.append(hls)
        return (h, hls)
    }

    private func load(_ h: EngineHarness, selection: TrackSelection = TrackSelection()) async -> Bool {
        h.engine.perform(.load(Epoch(1), film, startAt: 0, selection: selection, quality: nil))
        return await h.waitFor(.engineReady(Epoch(1)))
    }

    private func groups(of item: AVPlayerItem) async throws -> (audible: AVMediaSelectionGroup, legible: AVMediaSelectionGroup) {
        let audible = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let legible = try await item.asset.loadMediaSelectionGroup(for: .legible)
        return (try XCTUnwrap(audible), try XCTUnwrap(legible))
    }

    /// "en", "de" and whether it is a forced one, for what the item has selected in the group.
    private func subtitle(of item: AVPlayerItem, in group: AVMediaSelectionGroup) -> String? {
        guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return (option.extendedLanguageTag ?? "?") + (option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) ? " forced" : "")
    }

    private func audio(of item: AVPlayerItem, in group: AVMediaSelectionGroup) -> String? {
        item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag
    }

    // MARK: - The applier on an item

    func testTheDefaultApplierLeavesAForcedSubtitleThatAVFoundationChoseAloneWhenNoSubtitleIsChosenAndItFollowsTheAudio() async throws {
        let hls = try await HLSFixture.start(seconds: 10, forcedSubtitles: ["en", "de"])
        let player = AVPlayer()
        player.isMuted = true
        let item = AVPlayerItem(url: hls.masterURL())
        player.replaceCurrentItem(with: item)
        let h = try EngineHarness()
        let ready = await h.wait { item.status == .readyToPlay }
        XCTAssertTrue(ready, "\(String(describing: item.error))")
        let (audible, legible) = try await groups(of: item)
        XCTAssertEqual(subtitle(of: item, in: legible), "en forced", "AVFoundation chose it on its own (else this test shows nothing)")

        // A start with no choice for the subtitles: "off" is not said, because nothing the viewer chose is on.
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: nil, subtitle: nil))
        XCTAssertEqual(subtitle(of: item, in: legible), "en forced", "left alone: the applier did not make 'off' a choice of the group")
        // ... which is why the forced subtitles still follow the audio: a choice of the group would have ended that.
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 1, subtitle: nil))
        XCTAssertEqual(audio(of: item, in: audible), "de")
        let followed = await h.wait { self.subtitle(of: item, in: legible) == "de forced" }
        XCTAssertTrue(followed, "the German audio brings the German forced subtitles: \(String(describing: subtitle(of: item, in: legible)))")
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: 0, subtitle: nil))
        let back = await h.wait { self.subtitle(of: item, in: legible) == "en forced" }
        XCTAssertTrue(back, "and the English audio the English: \(String(describing: subtitle(of: item, in: legible)))")
    }

    func testTheDefaultApplierTurnsOffAnOrdinarySubtitleThatIsOnWhenNoSubtitleIsChosen() async throws {
        // What it has always done, for a subtitle AVFoundation put on because of the machine's settings: the app says "off", and off it is.
        let hls = try await HLSFixture.start(seconds: 10, forcedSubtitles: ["en"])
        let player = AVPlayer()
        player.isMuted = true
        let item = AVPlayerItem(url: hls.masterURL())
        player.replaceCurrentItem(with: item)
        let h = try EngineHarness()
        let ready = await h.wait { item.status == .readyToPlay }
        XCTAssertTrue(ready)
        let (_, legible) = try await groups(of: item)
        item.select(legible.options[1], in: legible)      // German, not forced
        XCTAssertEqual(subtitle(of: item, in: legible), "de")
        await AVPlayerEngine.defaultApplier(item, TrackSelection(audio: nil, subtitle: nil))
        XCTAssertNil(subtitle(of: item, in: legible), "a subtitle that is not a forced one does not stay on for an 'off'")
    }

    // MARK: - Through the engine

    func testALoadWithoutASubtitleChoiceKeepsTheForcedSubtitleOnAndThePlayerLoadsIt() async throws {
        let (h, hls) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready, "events: \(h.events)")
        let item = try XCTUnwrap(h.player.currentItem)
        let (_, legible) = try await groups(of: item)
        XCTAssertEqual(subtitle(of: item, in: legible), "en forced", "the session is up with the forced subtitle on, as AVFoundation chose it")
        h.engine.perform(.play(Epoch(1)))
        let loaded = await h.wait { hls.server.requestedPaths.contains(hls.subtitleSegmentPath(code: "forced-en")) }
        XCTAssertTrue(loaded, "and it is the forced subtitle that the player loads, not only a mark on the item: \(hls.server.requestedPaths)")
        XCTAssertFalse(hls.server.requestedPaths.contains(hls.subtitleSegmentPath(code: "en")), "none of the others")
    }

    func testForcedSubtitlesFollowTheAudioThatTheViewerChoosesWhileTheViewerHasChosenNoSubtitle() async throws {
        let (h, hls) = try await rig()
        let ready = await load(h)
        XCTAssertTrue(ready)
        h.engine.perform(.play(Epoch(1)))
        let item = try XCTUnwrap(h.player.currentItem)
        let (audible, legible) = try await groups(of: item)
        XCTAssertEqual(subtitle(of: item, in: legible), "en forced")

        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 1, subtitle: nil)))
        let german = await h.wait { self.audio(of: item, in: audible) == "de" && self.subtitle(of: item, in: legible) == "de forced" }
        XCTAssertTrue(german, "audio \(String(describing: audio(of: item, in: audible))), subtitle \(String(describing: subtitle(of: item, in: legible)))")
        let loaded = await h.wait { hls.server.requestedPaths.contains(hls.subtitleSegmentPath(code: "forced-de")) }
        XCTAssertTrue(loaded, "the player loads the German forced subtitles now: \(hls.server.requestedPaths)")

        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: nil, subtitle: nil)))
        let english = await h.wait { self.audio(of: item, in: audible) == "en" && self.subtitle(of: item, in: legible) == "en forced" }
        XCTAssertTrue(english, "and back: audio \(String(describing: audio(of: item, in: audible))), subtitle \(String(describing: subtitle(of: item, in: legible)))")
        XCTAssertEqual(h.stalls(of: Epoch(1)), 0, "none of it is a stall: \(h.events.filter { if case .engineTick = $0 { return false } else { return true } })")
    }

    func testAViewerWhoTurnsOffASubtitleHeChoseTurnsOffAForcedOneToo() async throws {
        // The viewer picked the forced subtitles from the list (option 2) and now says "off": it is off, not left on because it is a forced one.
        let (h, _) = try await rig()
        let ready = await load(h, selection: TrackSelection(audio: nil, subtitle: 2))
        XCTAssertTrue(ready)
        let item = try XCTUnwrap(h.player.currentItem)
        let (audible, legible) = try await groups(of: item)
        XCTAssertEqual(subtitle(of: item, in: legible), "en forced")

        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: nil, subtitle: nil)))
        let off = await h.wait { self.subtitle(of: item, in: legible) == nil }
        XCTAssertTrue(off, "off is off: \(String(describing: subtitle(of: item, in: legible)))")
        // And it stays off - that is a choice of the viewer, which the German audio does not undo.
        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: 1, subtitle: nil)))
        let german = await h.wait { self.audio(of: item, in: audible) == "de" }
        XCTAssertTrue(german)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(subtitle(of: item, in: legible), "no forced subtitles after the viewer's own 'off'")
    }

    func testAViewerWhoTurnsOffAnOrdinarySubtitleHasNoSubtitlesLeft() async throws {
        let (h, _) = try await rig()
        let ready = await load(h, selection: TrackSelection(audio: nil, subtitle: 0))
        XCTAssertTrue(ready)
        let item = try XCTUnwrap(h.player.currentItem)
        let (_, legible) = try await groups(of: item)
        XCTAssertEqual(subtitle(of: item, in: legible), "en", "the viewer's English, in place of the forced one AVFoundation had chosen")
        h.engine.perform(.applySelection(Epoch(1), TrackSelection(audio: nil, subtitle: nil)))
        let off = await h.wait { self.subtitle(of: item, in: legible) == nil }
        XCTAssertTrue(off, "\(String(describing: subtitle(of: item, in: legible)))")
    }
}
