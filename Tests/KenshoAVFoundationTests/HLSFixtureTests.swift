import XCTest
import AVFoundation
@testable import KenshoAVFoundation

/// The loopback server and the stream the other HLS tests stand on: that they are what those tests assume, so that a failure there is the engine's and
/// not the fixture's.
@MainActor
final class HLSFixtureTests: XCTestCase {
    private func get(_ url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    // MARK: - The server

    func testTheServerAnswersWhatItServesAndNotFoundForTheRest() async throws {
        let server = try LoopbackHTTPServer()
        try await server.start()
        server.serve(Data("0123456789".utf8), at: "/ten", contentType: "text/plain")
        let (body, response) = try await get(server.url("/ten"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "0123456789")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/plain")
        let (_, missing) = try await get(server.url("/nothing"))
        XCTAssertEqual(missing.statusCode, 404)
        let (part, ranged) = try await get(server.url("/ten"), range: "bytes=2-4")
        XCTAssertEqual(ranged.statusCode, 206)
        XCTAssertEqual(String(decoding: part, as: UTF8.self), "234")
        XCTAssertEqual(ranged.value(forHTTPHeaderField: "Content-Range"), "bytes 2-4/10")
        XCTAssertEqual(server.requestedPaths, ["/ten", "/nothing", "/ten"], "every request is in the log, in order, whoever answered it")
    }

    func testAHeldRequestIsAnsweredOnlyWhenTheTestReleasesItAndLaterOnesAtOnce() async throws {
        let server = try LoopbackHTTPServer()
        try await server.start()
        server.serve(Data("late".utf8), at: "/held", contentType: "text/plain")
        server.hold("/held")
        let url = server.url("/held")
        let answered = Task { try await self.get(url).0 }
        // The request is there, read and kept: that is what makes the client wait without ever hearing "no".
        var waiting = 0
        for _ in 0..<100 where waiting == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waiting = server.waitingCount(of: "/held")
        }
        XCTAssertEqual(waiting, 1)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(server.waitingCount(of: "/held"), 1, "still not answered")
        XCTAssertTrue(server.answeredPaths.isEmpty)
        server.release("/held")
        let body = try await answered.value
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "late")
        XCTAssertEqual(server.waitingCount(of: "/held"), 0)
        let (again, _) = try await get(url)
        XCTAssertEqual(String(decoding: again, as: UTF8.self), "late", "released means released: the next request is not held")
    }

    func testAFailingPathAnswersWithItsStatusInsteadOfItsResource() async throws {
        let server = try LoopbackHTTPServer()
        try await server.start()
        server.serve(Data("fine".utf8), at: "/seg", contentType: "text/plain")
        server.fail("/seg", status: 503)
        let (_, response) = try await get(server.url("/seg"))
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertTrue(server.answeredPaths.isEmpty, "it was not served")
    }

    // MARK: - The stream

    func testTheSegmentsAreWhatTheOtherTestsCountOn() async throws {
        let hls = try await HLSFixture.start(seconds: 30)
        XCTAssertEqual(hls.segmentDurations.count, 16, "fifteen segments of about two seconds and the rest")
        XCTAssertEqual(hls.segmentDurations.dropLast().allSatisfy { abs($0 - 2) < 0.05 }, true, "\(hls.segmentDurations)")
        XCTAssertEqual(hls.segmentStart(3), 6, accuracy: 0.05)
        XCTAssertEqual(hls.segmentStart(6), 12, accuracy: 0.05)
        XCTAssertEqual(hls.segmentIndex(at: 6.5), 3)
        XCTAssertEqual(hls.segmentIndex(at: 12.0), 5, "12.0 is just before the segment that begins at 12.005")
        XCTAssertEqual(hls.segmentIndex(at: 12.1), 6)
        XCTAssertEqual(hls.segmentIndex(at: 1_000), hls.segmentDurations.count - 1)
        // A playlist names every segment the server has.
        let (playlist, _) = try await get(hls.server.url(hls.playlistPath(audio: "en")))
        let text = String(decoding: playlist, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "#EXTINF:").count - 1, hls.segmentDurations.count)
        XCTAssertTrue(text.contains("#EXT-X-ENDLIST"), "a video-on-demand stream: the length is known from the start")
    }

    func testAnAVPlayerPlaysTheFixtureAsAnHLSStreamOverHTTPWithTheGroupsOfAMultiTrackStream() async throws {
        let hls = try await HLSFixture.start(seconds: 30)
        let player = AVPlayer()
        player.isMuted = true
        let item = AVPlayerItem(url: hls.masterURL())
        player.replaceCurrentItem(with: item)
        var ready = false
        for _ in 0..<500 where !ready {
            try await Task.sleep(nanoseconds: 10_000_000)
            ready = item.status != .unknown
        }
        XCTAssertEqual(item.status, .readyToPlay, "\(String(describing: item.error))")
        XCTAssertEqual(item.duration.seconds, 30, accuracy: 0.2)

        let loadedAudible = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let audible = try XCTUnwrap(loadedAudible)
        XCTAssertEqual(audible.options.map(\.extendedLanguageTag), ["en", "de"], "in the order of the master playlist: the numbers of a selection are positions in it")
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: audible)?.extendedLanguageTag, "en", "the one AVFoundation may choose on its own, whatever the language of the machine")
        let loadedLegible = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let legible = try XCTUnwrap(loadedLegible)
        XCTAssertEqual(legible.options.map(\.extendedLanguageTag), ["en", "de"])
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: legible), "no subtitle unless one is asked for")
        XCTAssertTrue(legible.allowsEmptySelection)

        player.play()
        var moved = false
        for _ in 0..<500 where !moved {
            try await Task.sleep(nanoseconds: 10_000_000)
            moved = player.currentTime().seconds > 1
        }
        XCTAssertTrue(moved, "it plays: at \(player.currentTime().seconds)")
        let paths = hls.server.requestedPaths
        XCTAssertEqual(paths.first, hls.masterPath(), "it began at the master playlist, over HTTP")
        XCTAssertTrue(paths.contains(hls.segmentPath(audio: "en", 0)), "and took its segments one by one: \(paths)")
        XCTAssertTrue(paths.contains("/hi/audio-en/init.mp4"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("/hi/audio-de/seg") }, "the rendition it was not asked for is not loaded: \(paths)")
    }

    func testTwoVariantsAreTwoStreamsToTheServerAndTheSameToThePlayer() async throws {
        let hls = try await HLSFixture.start(seconds: 10)
        let (hi, _) = try await get(hls.masterURL("hi"))
        let (lo, _) = try await get(hls.masterURL("lo"))
        XCTAssertEqual(hi, lo)
        let (a, _) = try await get(hls.server.url(hls.segmentPath("hi", audio: "en", 1)))
        let (b, _) = try await get(hls.server.url(hls.segmentPath("lo", audio: "de", 1)))
        XCTAssertEqual(a, b, "the same bytes at their own paths: which one the player loaded is in the log of the server")
        XCTAssertFalse(a.isEmpty)
    }
}
