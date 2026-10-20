import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import UniformTypeIdentifiers

/// A small HLS stream made at test time and served from the loopback (`LoopbackHTTPServer`), so that `AVPlayerEngine` meets what it meets in the apps: a
/// master playlist, alternate audio and subtitle renditions that are an `AVMediaSelectionGroup`, segments that come over HTTP one by one - and one
/// that a test can keep back, so that the player runs dry in the middle of playing.
///
/// Silent (a test run must not make a sound): fragmented MPEG-4 AAC segments written by `AVAssetWriter` in the HLS profile (the AAC itself is encoded outside
/// the writer: see `HLSStreamWriter.silentAAC`). By default the stream has no
/// picture - that is no matter to the things the engine does (starting, jumping, stalling, choosing a track, swapping an item), and a picture makes
/// every test cost the encoder. With a `Picture` the master has a video variant as well: H.264 in segments of its own, a keyframe at least every
/// `keyframeSeconds`, black but for the number of the frame (`PictureCode`) - for what only a picture shows: where a jump lands (on a keyframe, at the
/// start of a segment or on the second), which frame is on the screen when the clock says it is at a time, whether a stream that has video swaps, stalls and
/// changes its audio as one that has not. The encoder runs once per kind of stream and process; a test that asks for the same picture again gets the same bytes.
/// Nothing is shipped as a file: the segments are written when the fixture is made.
///
/// Layout, for each variant name (`hi`, `lo`; the same bytes, under their own paths, so a test can tell which one the player loaded):
///
///     /<variant>/master.m3u8                      audio group "aud" (en, de), subtitle group "sub" (en, de, and forced ones on request), one variant stream
///     /<variant>/audio-<en|de>.m3u8               the media playlists
///     /<variant>/audio-<en|de>/init.mp4           and their segments: init.mp4, seg0.m4s ...
///     /<variant>/audio-<en|de>/seg<N>.m4s
///     /<variant>/video.m3u8                       the picture (only with one): the variant stream is this playlist, the audio comes from the group
///     /<variant>/video/init.mp4
///     /<variant>/video/seg<N>.m4s
///     /<variant>/subs-<en|de|forced-xx>.m3u8      WebVTT, one segment for the whole stream
///     /<variant>/subs-<en|de|forced-xx>/seg0.vtt
final class HLSFixture {
    struct Rendition {
        var code: String
        var language: String
        var name: String
    }

    /// The picture of a stream that has one.
    struct Picture: Hashable, Sendable {
        var width = 320
        var height = 180
        var framesPerSecond = 24
        /// The longest a group of pictures may be. The writer starts a segment at the first keyframe after the segment interval, so with the interval of
        /// the stream equal to this a segment is one group of pictures; with a longer interval a segment holds several keyframes, and a jump can land on
        /// one of those inside it.
        var keyframeSeconds: TimeInterval = 2

        func frame(at time: TimeInterval) -> Int { Int((time * Double(framesPerSecond)).rounded()) }
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
    let picture: Picture?
    /// The length of each segment of the picture; empty without one.
    let videoSegmentDurations: [TimeInterval]
    /// The presentation time of each keyframe of the picture, as the encoder wrote it (read back from the segments, not assumed); empty without a picture.
    let keyframes: [TimeInterval]
    /// The subtitles that are forced (FORCED=YES, AUTOSELECT=YES; the first of them DEFAULT=YES), the last options of the subtitle group, in this order.
    let forcedSubtitles: [Rendition]
    private let video: HLSStreamWriter.Stream?

    private init(
        server: LoopbackHTTPServer, seconds: TimeInterval, audio: HLSStreamWriter.Stream, video: HLSStreamWriter.Stream?, picture: Picture?,
        variants: [String], forcedSubtitles: [Rendition]
    ) {
        self.server = server
        self.seconds = seconds
        self.segmentDurations = audio.segments.map(\.duration)
        self.variants = variants
        self.picture = picture
        self.video = video
        self.videoSegmentDurations = video?.segments.map(\.duration) ?? []
        self.keyframes = video?.segments.flatMap(\.keyframes) ?? []
        self.forcedSubtitles = forcedSubtitles
    }

    deinit { server.stop() }

    /// - Parameters:
    ///   - seconds: how long the stream is.
    ///   - segmentSeconds: the length the writer aims at for each segment (of the audio and, if there is one, of the picture).
    ///   - variants: the path names under which the stream is served.
    ///   - picture: gives the stream a picture.
    ///   - forcedSubtitles: the languages of subtitle renditions that are forced (the way a film marks its foreign-language lines); the first is the default.
    ///     AVFoundation chooses the forced one whose language is the audio's, on its own, as long as nobody has chosen a subtitle.
    static func start(
        seconds: TimeInterval = 30, segmentSeconds: TimeInterval = 2, variants: [String] = ["hi", "lo"], picture: Picture? = nil,
        forcedSubtitles languages: [String] = []
    ) async throws -> HLSFixture {
        let audio = try await HLSStreamWriter.silentAAC(seconds: seconds, segmentSeconds: segmentSeconds)
        var video: HLSStreamWriter.Stream?
        if let picture { video = try await HLSStreamWriter.cachedPicture(picture, seconds: seconds, segmentSeconds: segmentSeconds) }
        let server = try LoopbackHTTPServer()
        try await server.start()
        let forced = languages.map { Rendition(code: "forced-\($0)", language: $0, name: "Forced (\($0))") }
        let fixture = HLSFixture(server: server, seconds: seconds, audio: audio, video: video, picture: picture, variants: variants, forcedSubtitles: forced)
        for variant in variants { fixture.publish(audio, as: variant) }
        return fixture
    }

    // MARK: - Where things are

    func masterURL(_ variant: String = "hi") -> URL { server.url(masterPath(variant)) }
    func masterPath(_ variant: String = "hi") -> String { "/\(variant)/master.m3u8" }
    func playlistPath(_ variant: String = "hi", audio code: String) -> String { "/\(variant)/audio-\(code).m3u8" }
    func segmentPath(_ variant: String = "hi", audio code: String = "en", _ index: Int) -> String { "/\(variant)/audio-\(code)/seg\(index).m4s" }
    func subtitlePlaylistPath(_ variant: String = "hi", code: String) -> String { "/\(variant)/subs-\(code).m3u8" }
    func subtitleSegmentPath(_ variant: String = "hi", code: String) -> String { "/\(variant)/subs-\(code)/seg0.vtt" }
    func videoPlaylistPath(_ variant: String = "hi") -> String { "/\(variant)/video.m3u8" }
    func videoInitializationPath(_ variant: String = "hi") -> String { "/\(variant)/video/init.mp4" }
    func videoSegmentPath(_ index: Int, variant: String = "hi") -> String { "/\(variant)/video/seg\(index).m4s" }

    /// Keeps back segment `index` in every audio rendition of `variant` (the player loads the one it has selected, and a test should not depend on which).
    func holdSegment(_ index: Int, variant: String = "hi") {
        for rendition in Self.audioRenditions { server.hold(segmentPath(variant, audio: rendition.code, index)) }
    }

    func releaseSegment(_ index: Int, variant: String = "hi") {
        for rendition in Self.audioRenditions { server.release(segmentPath(variant, audio: rendition.code, index)) }
    }

    /// Keeps back segment `index` of the picture.
    func holdVideoSegment(_ index: Int, variant: String = "hi") { server.hold(videoSegmentPath(index, variant: variant)) }
    func releaseVideoSegment(_ index: Int, variant: String = "hi") { server.release(videoSegmentPath(index, variant: variant)) }

    /// The index of the segment that holds `time`.
    func segmentIndex(at time: TimeInterval) -> Int {
        Self.index(at: time, in: segmentDurations)
    }

    /// Where the segment begins.
    func segmentStart(_ index: Int) -> TimeInterval { segmentDurations.prefix(index).reduce(0, +) }

    /// The same for the picture, whose segments are cut at keyframes and are not as long as the audio's.
    func videoSegmentIndex(at time: TimeInterval) -> Int { Self.index(at: time, in: videoSegmentDurations) }
    func videoSegmentStart(_ index: Int) -> TimeInterval { videoSegmentDurations.prefix(index).reduce(0, +) }

    /// The last keyframe at or before `time`, and the first after it (nil past the last).
    func keyframes(around time: TimeInterval) -> (before: TimeInterval?, after: TimeInterval?) {
        (keyframes.last { $0 <= time + 1e-6 }, keyframes.first { $0 > time + 1e-6 })
    }

    private static func index(at time: TimeInterval, in durations: [TimeInterval]) -> Int {
        var end = 0.0
        for (index, duration) in durations.enumerated() {
            end += duration
            if time < end { return index }
        }
        return durations.count - 1
    }

    // MARK: - Publishing

    private func publish(_ stream: HLSStreamWriter.Stream, as variant: String) {
        server.serve(Data(master(variant).utf8), at: masterPath(variant), contentType: "application/vnd.apple.mpegurl")
        for rendition in Self.audioRenditions {
            let base = "/\(variant)/audio-\(rendition.code)"
            server.serve(Data(mediaPlaylist(stream, map: "audio-\(rendition.code)").utf8), at: "\(base).m3u8", contentType: "application/vnd.apple.mpegurl")
            server.serve(stream.initialization, at: "\(base)/init.mp4", contentType: "video/mp4")
            for (index, segment) in stream.segments.enumerated() {
                server.serve(segment.data, at: "\(base)/seg\(index).m4s", contentType: "video/iso.segment")
            }
        }
        if let video {
            server.serve(Data(mediaPlaylist(video, map: "video").utf8), at: videoPlaylistPath(variant), contentType: "application/vnd.apple.mpegurl")
            server.serve(video.initialization, at: videoInitializationPath(variant), contentType: "video/mp4")
            for (index, segment) in video.segments.enumerated() {
                server.serve(segment.data, at: videoSegmentPath(index, variant: variant), contentType: "video/iso.segment")
            }
        }
        for rendition in Self.subtitleRenditions + forcedSubtitles {
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
        for (index, rendition) in forcedSubtitles.enumerated() {
            lines.append(
                "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"sub\",NAME=\"\(rendition.name)\",LANGUAGE=\"\(rendition.language)\","
                    + "DEFAULT=\(index == 0 ? "YES" : "NO"),AUTOSELECT=YES,FORCED=YES,URI=\"subs-\(rendition.code).m3u8\""
            )
        }
        if let video, let picture {
            let peak = video.segments.map { Double($0.data.count) * 8 / max($0.duration, 0.1) }.max() ?? 0
            let average = Double(video.segments.reduce(0) { $0 + $1.data.count }) * 8 / max(video.segments.reduce(0) { $0 + $1.duration }, 0.1)
            let codec = FragmentedMP4.avcCodecString(initialization: video.initialization) ?? "avc1.640015"
            lines.append(
                "#EXT-X-STREAM-INF:BANDWIDTH=\(Int(peak) + 48_000),AVERAGE-BANDWIDTH=\(Int(average) + 40_000),CODECS=\"\(codec),mp4a.40.2\","
                    + "RESOLUTION=\(picture.width)x\(picture.height),FRAME-RATE=\(picture.framesPerSecond).000,VIDEO-RANGE=SDR,AUDIO=\"aud\",SUBTITLES=\"sub\""
            )
            lines.append("video.m3u8")
        } else {
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=48000,AVERAGE-BANDWIDTH=40000,CODECS=\"mp4a.40.2\",AUDIO=\"aud\",SUBTITLES=\"sub\"")
            lines.append("audio-\(Self.audioRenditions[0].code).m3u8")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// (The URIs are relative to the playlist: `/hi/audio-en.m3u8` names `audio-en/seg0.m4s`.)
    private func mediaPlaylist(_ stream: HLSStreamWriter.Stream, map directory: String) -> String {
        let target = Int(ceil(stream.segments.map(\.duration).max() ?? 1))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"\(directory)/init.mp4\"",
        ]
        for (index, segment) in stream.segments.enumerated() {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("\(directory)/seg\(index).m4s")
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

/// A value made once for each key in a process and shared by everybody who asks - the encoders are what a test with a stream pays for, and a stream is only
/// bytes. A failed attempt is not kept.
final class MadeOnce<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Key: Task<Value, Error>] = [:]

    func value(for key: Key, make: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task: Task<Value, Error> = lock.withLock {
            if let existing = tasks[key] { return existing }
            let created = Task { try await make() }
            tasks[key] = created
            return created
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { tasks[key] = nil }
            throw error
        }
    }
}

/// Writes silence, and a picture, as the segments of an HLS stream.
enum HLSStreamWriter {
    struct Segment: Sendable {
        var data: Data
        var duration: TimeInterval
        /// The presentation times of the samples a decoder can start at, if the track has any to tell (a picture's: read back from the segment).
        var keyframes: [TimeInterval] = []
    }

    struct Stream: Sendable {
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

    // MARK: - The sound

    /// AAC packets of silence, as `AVAssetReader` hands them out: chunks of packets with the format description that the writer needs.
    struct SilentPackets: @unchecked Sendable {
        var format: CMFormatDescription
        var samples: [CMSampleBuffer]
    }

    private static let packets = MadeOnce<TimeInterval, SilentPackets>()

    /// Silence as the segments of an HLS stream.
    ///
    /// The AAC is **not** encoded by the writer. The encoder inside an `AVAssetWriter` in the HLS profile is the one part of this fixture that cannot be relied
    /// on (macOS 27): used again and again, generation after generation, it fails (`AVFoundationErrorDomain -11800` with `-12780` or `-12706` underneath)
    /// or takes the whole process down (SIGTRAP or SIGSEGV on the writer's queue in MediaToolbox, `fncHandleDeferredNotification`) - every one of eight
    /// processes died within 300 generations in a row, after 5 to 90 of them, and three of six within 60 with 300 ms between them; keeping the writer alive
    /// longer, appending the other documented way (`requestMediaDataWhenReady`) and waiting between the generations did not help. A full test
    /// run of another session met it as `-12780`. The packets are therefore made by the encoder of `AVAudioFile` (the one `TestMedia` has always used), read back compressed, and
    /// the writer only muxes them (`outputSettings: nil`): 3200 generations that way, eight processes at a time under load, without one failure. The segments
    /// are the ones the encoder in the writer made, to the millisecond (30 s: 16 segments, 30.0698 s). The picture's H.264 encoder inside the writer
    /// did not show it (600 generations, six processes at a time).
    static func silentAAC(seconds: TimeInterval, segmentSeconds: TimeInterval) async throws -> Stream {
        let silence = try await packets.value(for: seconds) { try await encodePackets(seconds: seconds) }
        let collector = Collector()
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: silence.format)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for sample in silence.samples {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.append(sample) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        guard let stream = collector.result else { throw CocoaError(.fileReadCorruptFile) }
        return stream
    }

    /// `seconds` of silence written to a file by `AVAudioFile` and read back as the compressed packets it holds. The packets are copies in memory: they
    /// are the same bytes after the file is gone.
    private static func encodePackets(seconds: TimeInterval) async throws -> SilentPackets {
        let directory = try TestMedia.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestMedia.silentAudio(seconds: seconds, in: directory, name: "silence")
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        guard reader.status == .completed, let first = samples.first, let format = CMSampleBufferGetFormatDescription(first) else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        return SilentPackets(format: format, samples: samples)
    }

    // MARK: - The picture

    private static let pictures = MadeOnce<String, Stream>()
    private static let encodingLock = NSLock()
    nonisolated(unsafe) private static var encoded = 0
    /// How often the encoder has run in this process (a test of the cache counts it).
    static var pictureEncodings: Int { encodingLock.withLock { encoded } }

    /// The picture stream, made once for each kind: the encoder is what a test with a picture pays for, and a stream is only bytes.
    static func cachedPicture(_ picture: HLSFixture.Picture, seconds: TimeInterval, segmentSeconds: TimeInterval) async throws -> Stream {
        try await pictures.value(for: "\(picture)-\(seconds)-\(segmentSeconds)") {
            try await self.picture(picture, seconds: seconds, segmentSeconds: segmentSeconds)
        }
    }

    /// H.264 frames of the picture, cut into segments at keyframes. The keyframes are read back out of the segments: what the encoder was asked for is a
    /// maximum, and a test about where a jump lands must know where the keyframes are.
    static func picture(_ picture: HLSFixture.Picture, seconds: TimeInterval, segmentSeconds: TimeInterval) async throws -> Stream {
        encodingLock.withLock { encoded += 1 }
        let collector = Collector()
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: picture.width, AVVideoHeightKey: picture.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalDurationKey: picture.keyframeSeconds,
                AVVideoExpectedSourceFrameRateKey: picture.framesPerSecond,
                // (No frame reordering: a presentation time is then the decode time, and a keyframe is the first frame of its group.)
                AVVideoAllowFrameReorderingKey: false,
                AVVideoAverageBitRateKey: 300_000,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: picture.width, kCVPixelBufferHeightKey as String: picture.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let frames = Int((seconds * Double(picture.framesPerSecond)).rounded())
        for number in 0..<frames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var made: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
                throw writer.error ?? CocoaError(.coderInvalidValue)
            }
            PictureCode.draw(number, into: buffer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(number), timescale: CMTimeScale(picture.framesPerSecond))) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        guard var stream = collector.result, let timescale = FragmentedMP4.timescale(initialization: stream.initialization) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for index in stream.segments.indices {
            let samples = FragmentedMP4.samples(in: stream.segments[index].data, timescale: timescale)
            stream.segments[index].keyframes = samples.filter(\.isSync).map(\.time)
        }
        return stream
    }
}
