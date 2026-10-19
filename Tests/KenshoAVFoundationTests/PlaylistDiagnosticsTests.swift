import XCTest
import AVFoundation
import Kensho
@testable import KenshoAVFoundation

/// Serves canned answers for `https://stub.kensho.test/…` to `URLSession.shared`.
final class StubProtocol: URLProtocol {
    typealias Answer = (status: Int, headers: [String: String], body: Data)
    static var handler: ((URLRequest) -> Answer?)?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.kensho.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let answer = Self.handler?(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RecordingSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func write(_ line: String, tag: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append("[\(tag)] \(line)")
    }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    var text: String { lines.joined(separator: "\n") }
}

final class PlaylistDiagnosticsTests: XCTestCase {
    private let base = URL(string: "https://stub.kensho.test/session/master.m3u8")!
    private var sink: RecordingSink!
    private var log: KenshoLog!

    override func setUp() {
        URLProtocol.registerClass(StubProtocol.self)
        sink = RecordingSink()
        log = KenshoLog(sinks: [sink])
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        StubProtocol.handler = nil
    }

    private let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="hvc1.2.4.L150.B0,ec-3",VIDEO-RANGE=PQ
    index.m3u8
    """

    private let media = """
    #EXTM3U
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:6.0,
    seg0.m4s
    #EXTINF:6.0,
    seg1.m4s
    """

    /// Bytes that are not text.
    private let binary = Data([0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81])

    private func serve(_ files: [String: StubProtocol.Answer]) {
        StubProtocol.handler = { request in files[request.url?.lastPathComponent ?? ""] }
    }

    private func playlistFiles() -> [String: StubProtocol.Answer] {
        [
            "master.m3u8": (200, ["Content-Type": "application/vnd.apple.mpegurl"], Data(master.utf8)),
            "index.m3u8": (200, ["Content-Type": "application/vnd.apple.mpegurl"], Data(media.utf8)),
            "init.mp4": (200, ["Content-Type": "video/mp4"], binary),
            "seg0.m4s": (200, ["Content-Type": "video/iso.segment"], binary),
        ]
    }

    // MARK: - The graph

    func testTheGraphIsFollowedFromMasterToTheFirstSegment() async {
        serve(playlistFiles())
        await PlaylistDiagnostics.probeGraph(from: base, depth: 0, kind: "", log: log, tag: "initial", describeBinary: nil)
        let text = sink.text
        XCTAssertTrue(text.contains("depth=0 master.m3u8 status=200"), text)
        XCTAssertTrue(text.contains("depth=0 master.m3u8 STREAM-INF: #EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS=\"hvc1.2.4.L150.B0,ec-3\""), "the codec claim has a line of its own")
        XCTAssertTrue(text.contains("depth=1 (media-playlist) index.m3u8 status=200"), text)
        XCTAssertTrue(text.contains("segment count declared: 2"))
        XCTAssertTrue(text.contains("depth=2 (init-segment) init.mp4 status=200"), "the init segment is fetched although its tag looks like any other")
        XCTAssertTrue(text.contains("depth=2 (first-segment) seg0.m4s status=200"), text)
        XCTAssertFalse(text.contains("seg1.m4s status="), "only the first segment is fetched (the second is only named in the playlist body)")
    }

    func testEveryLineCarriesTheTagOfTheAttempt() async {
        serve(playlistFiles())
        await PlaylistDiagnostics.probeGraph(from: base, depth: 0, kind: "", log: log, tag: "fallback-2", describeBinary: nil)
        XCTAssertFalse(sink.lines.isEmpty)
        XCTAssertTrue(sink.lines.allSatisfy { $0.hasPrefix("[fallback-2] ") })
    }

    func testOnlyAMediaSegmentThatIsTooSmallIsSuspicious() async {
        serve(playlistFiles())
        await PlaylistDiagnostics.probeGraph(from: base, depth: 0, kind: "", log: log, tag: "t", describeBinary: nil)
        let lines = sink.lines
        let initLine = lines.first { $0.contains("(init-segment) init.mp4 — binary") } ?? ""
        let segmentLine = lines.first { $0.contains("(first-segment) seg0.m4s — binary") } ?? ""
        XCTAssertFalse(initLine.isEmpty)
        XCTAssertFalse(initLine.contains("suspiciously small"), "a few bytes of configuration are the nature of an init segment")
        XCTAssertTrue(segmentLine.contains("suspiciously small"), "a media segment of 6 bytes is a truncated read")
    }

    func testBinaryBodiesAreShownThroughTheCallersOutline() async {
        serve(playlistFiles())
        await PlaylistDiagnostics.probeGraph(from: base, depth: 0, kind: "", log: log, tag: "t") { "ftyp>moov(\($0.count))" }
        XCTAssertTrue(sink.text.contains("init.mp4 MP4 boxes: ftyp>moov(6)"))
    }

    func testWithoutAnOutlineOnlyStatusAndSizeAreLogged() async {
        serve(playlistFiles())
        await PlaylistDiagnostics.probeGraph(from: base, depth: 0, kind: "", log: log, tag: "t", describeBinary: nil)
        XCTAssertFalse(sink.text.contains("MP4 boxes"))
    }

    func testAMissingPlaylistIsLoggedAsFailedNotThrown() async {
        serve([:])
        await PlaylistDiagnostics.probeGraph(from: base, depth: 0, kind: "", log: log, tag: "t", describeBinary: nil)
        XCTAssertTrue(sink.text.contains("master.m3u8 FAILED"), sink.text)
    }

    func testTheWalkStopsAtDepthFour() async {
        // A playlist that points at itself.
        StubProtocol.handler = { _ in (200, [:], Data("#EXTM3U\nmaster.m3u8\n".utf8)) }
        await PlaylistDiagnostics.probeGraph(from: base, depth: 0, kind: "", log: log, tag: "t", describeBinary: nil)
        let fetches = sink.lines.filter { $0.contains("status=200") }
        XCTAssertEqual(fetches.count, 4)
    }

    // MARK: - The Range request

    private func rangeVerdict(status: Int, headers: [String: String] = [:], body: Data = Data()) async -> String {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-127")
            XCTAssertEqual(request.url?.lastPathComponent, "init.mp4")
            return (status, headers, body)
        }
        await PlaylistDiagnostics.probeRange(playlist: base, log: log, tag: "t")
        return sink.text
    }

    func testARangeRequestThatIsHonoredIsSaidSo() async {
        let text = await rangeVerdict(status: 206, headers: ["Content-Range": "bytes 0-127/400", "Accept-Ranges": "bytes"], body: Data(count: 128))
        XCTAssertTrue(text.contains("status=206 bytes-returned=128 Content-Range=bytes 0-127/400 Accept-Ranges=bytes"), text)
        XCTAssertTrue(text.contains("✓ honored"))
    }

    func testARangeRequestThatIsIgnoredIsLegalHTTP() async {
        let text = await rangeVerdict(status: 200, body: Data(count: 300))
        XCTAssertTrue(text.contains("status=200 bytes-returned=300"))
        XCTAssertTrue(text.contains("ignored (the whole file came back, which HTTP allows)"))
    }

    func testAnyOtherStatusToARangeRequestIsFlagged() async {
        let text = await rangeVerdict(status: 500)
        XCTAssertTrue(text.contains("unexpected status"), text)
    }

    // MARK: - The light probe and the verdict of AVFoundation

    func testTheLightProbeFetchesOnlyThePlaylist() async {
        var fetched: [String] = []
        StubProtocol.handler = { request in
            fetched.append(request.url?.lastPathComponent ?? "")
            return (200, [:], Data(self.master.utf8))
        }
        await PlaylistDiagnostics.probeReachable(playlist: base, log: log, tag: "t")
        XCTAssertEqual(fetched, ["master.m3u8"])
        XCTAssertTrue(sink.text.contains("loopback probe: OK status=200 bytes=\(master.utf8.count)"))
    }

    func testAnUnreachablePlaylistFailsTheLightProbeInTheLog() async {
        serve([:])
        await PlaylistDiagnostics.probeReachable(playlist: base, log: log, tag: "t")
        XCTAssertTrue(sink.text.contains("loopback probe: FAILED"))
    }

    func testAFileThatIsNotMediaIsNotPlayable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kensho-\(UUID().uuidString).m3u8")
        try Data("not a playlist".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await PlaylistDiagnostics.probePlayable(playlist: file, log: log, tag: "t")
        XCTAssertTrue(sink.text.contains("AVURLAsset probe:"), sink.text)
    }
}

final class PlayerItemLogDumpTests: XCTestCase {
    func testAnItemThatHasNotLoadedAnythingHasEmptyLogs() {
        let sink = RecordingSink()
        PlayerItemLogDump.dump(AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent.mp4")), log: KenshoLog(sinks: [sink]), tag: "initial")
        XCTAssertEqual(sink.lines, ["[initial] errorLog: empty", "[initial] accessLog: empty"])
    }

    /// The address AVPlayer asked for is the address of the stream, and a Jellyfin stream carries the account's token in it: the log is shared for
    /// diagnosis (it was not redacted before, in the log of the app either).
    func testTheAddressOfARequestIsLoggedWithoutTheTokenInItsQuery() {
        let line = PlayerItemLogDump.accessLine(index: 0, uri: "https://home.example:8920/Videos/abc/stream.mp4?Static=true&api_key=SECRET123&MediaSourceId=abc",
                                                requests: 3, bytes: 1_000, duration: 0.5, observedBitrate: 2e6, indicatedBitrate: 4e6, switchBitrate: 0, playbackType: "VOD")
        XCTAssertFalse(line.contains("SECRET123"), line)
        XCTAssertFalse(line.contains("api_key"), line)
        XCTAssertTrue(line.contains("uri=https://home.example:8920/Videos/abc/stream.mp4 requests=3"), "the host and the path stay: they are what the line is for: \(line)")
        XCTAssertTrue(line.contains("bytes=1000 duration=0.5 observedBitrate=2000000.0 indicatedBitrate=4000000.0 switchBitrate=0.0 playbackType=VOD"), line)
    }

    func testTheUriAndTheCommentOfAnErrorAreLoggedWithoutAToken() {
        let line = PlayerItemLogDump.errorLine(index: 1, date: "2026-10-19", uri: "https://home.example/Videos/abc/master.m3u8?api_key=SECRET123", server: "192.168.1.5",
                                               statusCode: 404, domain: "CoreMediaErrorDomain",
                                               comment: "Cannot read https://home.example/Videos/abc/seg0.m4s?X-Emby-Token=SECRET456 (access_token=SECRET789)")
        XCTAssertFalse(line.contains("SECRET"), line)
        XCTAssertTrue(line.contains("uri=https://home.example/Videos/abc/master.m3u8 server=192.168.1.5 statusCode=404 domain=CoreMediaErrorDomain comment=Cannot read https://home.example/Videos/abc/seg0.m4s"), line)
    }

    func testAMissingAddressIsAQuestionMarkAsBefore() {
        let line = PlayerItemLogDump.errorLine(index: 0, date: nil, uri: nil, server: nil, statusCode: 0, domain: "d", comment: nil)
        XCTAssertEqual(line, "  [0] date=? uri=? server=? statusCode=0 domain=d comment=?")
    }
}
