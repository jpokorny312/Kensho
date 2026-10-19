import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// A small HLS stream made at test time and served from the loopback (`LoopbackHTTPServer`), so that `AVPlayerEngine` meets what it meets in the apps: a
/// master playlist, alternate audio and subtitle renditions that are an `AVMediaSelectionGroup`, segments that come over HTTP one by one - and one
/// that a test can keep back, so that the player runs dry in the middle of playing.
///
/// Audio only, and silent (a test run must not make a sound): fragmented MPEG-4 AAC segments written by `AVAssetWriter` in the HLS profile. That the
/// stream has no picture is no matter to the things the engine does - starting, jumping, stalling, choosing a track, swapping an item - and a picture
/// would make every test cost the encoder. Nothing is shipped as a file: the segments are written when the fixture is made.
///
/// Layout, for each variant name (`hi`, `lo`; the same bytes, under their own paths, so a test can tell which one the player loaded):
///
///     /<variant>/master.m3u8                      audio group "aud" (en, de), subtitle group "sub" (en, de), one variant stream
///     /<variant>/audio-<en|de>.m3u8               the media playlists
///     /<variant>/audio-<en|de>/init.mp4           and their segments: init.mp4, seg0.m4s ...
///     /<variant>/audio-<en|de>/seg<N>.m4s
///     /<variant>/subs-<en|de>.m3u8                WebVTT, one segment for the whole stream
///     /<variant>/subs-<en|de>/seg0.vtt
final class HLSFixture {
    struct Rendition {
        var code: String
        var language: String
        var name: String
    }

    /// The renditions in the order of the master playlist - which is the order a test expects the options of the media selection groups in.
    static let audioRenditions = [
        Rendition(code: "en", language: "en", name: "English"),
        Rendition(code: "de", language: "de", name: "Deutsch"),
    ]
    static let subtitleRenditions = [
        Rendition(code: "en", language: "en", name: "English"),
        Rendition(code: "de", language: "de", name: "Deutsch"),
    ]

    let server: LoopbackHTTPServer
    let seconds: TimeInterval
    /// The length of each segment as it was written (AAC frames do not divide a second: the writer cuts at a frame).
    let segmentDurations: [TimeInterval]
    let variants: [String]

    private init(server: LoopbackHTTPServer, seconds: TimeInterval, segmentDurations: [TimeInterval], variants: [String]) {
        self.server = server
        self.seconds = seconds
        self.segmentDurations = segmentDurations
        self.variants = variants
    }

    deinit { server.stop() }

    /// - Parameters:
    ///   - seconds: how long the stream is.
    ///   - segmentSeconds: the length the writer aims at for each segment.
    ///   - variants: the path names under which the stream is served.
    static func start(seconds: TimeInterval = 30, segmentSeconds: TimeInterval = 2, variants: [String] = ["hi", "lo"]) async throws -> HLSFixture {
        let stream = try await HLSStreamWriter.silentAAC(seconds: seconds, segmentSeconds: segmentSeconds)
        let server = try LoopbackHTTPServer()
        try await server.start()
        let fixture = HLSFixture(server: server, seconds: seconds, segmentDurations: stream.segments.map(\.duration), variants: variants)
        for variant in variants { fixture.publish(stream, as: variant) }
        return fixture
    }

    // MARK: - Where things are

    func masterURL(_ variant: String = "hi") -> URL { server.url(masterPath(variant)) }
    func masterPath(_ variant: String = "hi") -> String { "/\(variant)/master.m3u8" }
    func playlistPath(_ variant: String = "hi", audio code: String) -> String { "/\(variant)/audio-\(code).m3u8" }
    func segmentPath(_ variant: String = "hi", audio code: String = "en", _ index: Int) -> String { "/\(variant)/audio-\(code)/seg\(index).m4s" }
    func subtitlePlaylistPath(_ variant: String = "hi", code: String) -> String { "/\(variant)/subs-\(code).m3u8" }
    func subtitleSegmentPath(_ variant: String = "hi", code: String) -> String { "/\(variant)/subs-\(code)/seg0.vtt" }

    /// Keeps back segment `index` in every audio rendition of `variant` (the player loads the one it has selected, and a test should not depend on which).
    func holdSegment(_ index: Int, variant: String = "hi") {
        for rendition in Self.audioRenditions { server.hold(segmentPath(variant, audio: rendition.code, index)) }
    }

    func releaseSegment(_ index: Int, variant: String = "hi") {
        for rendition in Self.audioRenditions { server.release(segmentPath(variant, audio: rendition.code, index)) }
    }

    /// The index of the segment that holds `time`.
    func segmentIndex(at time: TimeInterval) -> Int {
        var end = 0.0
        for (index, duration) in segmentDurations.enumerated() {
            end += duration
            if time < end { return index }
        }
        return segmentDurations.count - 1
    }

    /// Where the segment begins.
    func segmentStart(_ index: Int) -> TimeInterval { segmentDurations.prefix(index).reduce(0, +) }

    // MARK: - Publishing

    private func publish(_ stream: HLSStreamWriter.Stream, as variant: String) {
        server.serve(Data(master(variant).utf8), at: masterPath(variant), contentType: "application/vnd.apple.mpegurl")
        for rendition in Self.audioRenditions {
            let base = "/\(variant)/audio-\(rendition.code)"
            server.serve(Data(mediaPlaylist(stream, code: rendition.code).utf8), at: "\(base).m3u8", contentType: "application/vnd.apple.mpegurl")
            server.serve(stream.initialization, at: "\(base)/init.mp4", contentType: "video/mp4")
            for (index, segment) in stream.segments.enumerated() {
                server.serve(segment.data, at: "\(base)/seg\(index).m4s", contentType: "video/iso.segment")
            }
        }
        for rendition in Self.subtitleRenditions {
            let base = "/\(variant)/subs-\(rendition.code)"
            server.serve(Data(subtitlePlaylist(code: rendition.code).utf8), at: "\(base).m3u8", contentType: "application/vnd.apple.mpegurl")
            server.serve(Data(webVTT(for: rendition).utf8), at: "\(base)/seg0.vtt", contentType: "text/vtt")
        }
    }

    private func master(_ variant: String) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        // Only the first rendition may be chosen by AVFoundation on its own: left to itself it picks the one that matches the language of the machine the
        // test runs on, and a test that says "nothing chosen" would see English on one machine and German on the next.
        for (index, rendition) in Self.audioRenditions.enumerated() {
            lines.append(
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(rendition.name)\",LANGUAGE=\"\(rendition.language)\","
                    + "DEFAULT=\(index == 0 ? "YES" : "NO"),AUTOSELECT=\(index == 0 ? "YES" : "NO"),URI=\"audio-\(rendition.code).m3u8\""
            )
        }
        for rendition in Self.subtitleRenditions {
            // Neither default nor autoselect: no subtitle is on unless the viewer (or a test) asks for one.
            lines.append(
                "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"sub\",NAME=\"\(rendition.name)\",LANGUAGE=\"\(rendition.language)\","
                    + "DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI=\"subs-\(rendition.code).m3u8\""
            )
        }
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=48000,AVERAGE-BANDWIDTH=40000,CODECS=\"mp4a.40.2\",AUDIO=\"aud\",SUBTITLES=\"sub\"")
        lines.append("audio-\(Self.audioRenditions[0].code).m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    /// (The URIs are relative to the playlist: `/hi/audio-en.m3u8` names `audio-en/seg0.m4s`.)
    private func mediaPlaylist(_ stream: HLSStreamWriter.Stream, code: String) -> String {
        let target = Int(ceil(stream.segments.map(\.duration).max() ?? 1))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"audio-\(code)/init.mp4\"",
        ]
        for (index, segment) in stream.segments.enumerated() {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("audio-\(code)/seg\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    private func subtitlePlaylist(code: String) -> String {
        [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(ceil(seconds)))", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD",
            String(format: "#EXTINF:%.3f,", seconds), "subs-\(code)/seg0.vtt", "#EXT-X-ENDLIST",
        ].joined(separator: "\n") + "\n"
    }

    private func webVTT(for rendition: Rendition) -> String {
        "WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nHello in \(rendition.name)\n\n00:00:10.000 --> 00:00:14.000\nStill \(rendition.name)\n"
    }
}

/// Writes silence as the segments of an HLS stream.
enum HLSStreamWriter {
    struct Segment {
        var data: Data
        var duration: TimeInterval
    }

    struct Stream {
        var initialization: Data
        var segments: [Segment]
    }

    /// Collects what `AVAssetWriter` hands out in the HLS profile: the initialization segment once, then a segment each time the interval is full.
    private final class Collector: NSObject, AVAssetWriterDelegate {
        private let lock = NSLock()
        private var initialization: Data?
        private var segments: [Segment] = []

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
            lock.lock()
            defer { lock.unlock() }
            switch segmentType {
            case .initialization:
                initialization = segmentData
            case .separable:
                segments.append(Segment(data: segmentData, duration: segmentReport?.trackReports.first?.duration.seconds ?? 0))
            @unknown default:
                break
            }
        }

        var result: Stream? {
            lock.lock()
            defer { lock.unlock() }
            guard let initialization, !segments.isEmpty else { return nil }
            return Stream(initialization: initialization, segments: segments)
        }
    }

    static func silentAAC(seconds: TimeInterval, segmentSeconds: TimeInterval) async throws -> Stream {
        let sampleRate = 44_100.0
        let collector = Collector()
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let total = Int64(seconds * sampleRate)
        let chunk: Int64 = 4_096
        var written: Int64 = 0
        while written < total {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let frames = min(chunk, total - written)
            guard input.append(try silence(frames: Int(frames), from: written, sampleRate: sampleRate)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            written += frames
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        guard let stream = collector.result else { throw CocoaError(.fileReadCorruptFile) }
        return stream
    }

    /// 16-bit mono PCM of zeros; the writer's AAC encoder turns it into the packets of a segment.
    private static func silence(frames: Int, from start: Int64, sampleRate: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else { throw CocoaError(.coderInvalidValue) }
        let bytes = frames * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { throw CocoaError(.coderInvalidValue) }
        guard CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr else { throw CocoaError(.coderInvalidValue) }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(sampleRate)), packetDescriptions: nil, sampleBufferOut: &buffer
        ) == noErr, let buffer else { throw CocoaError(.coderInvalidValue) }
        return buffer
    }
}
