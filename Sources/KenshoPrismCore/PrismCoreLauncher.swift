import Foundation
import Kensho
import KenshoAVFoundation
import PrismCore
import Libavcodec
#if canImport(UIKit)
import UIKit
import AVFoundation
#endif

/// PrismCore would play the source without sound: it has audio tracks and
/// carries none of them (it leaves out a track it can neither copy nor
/// re-encode, and the film would play as silent video). See
/// `PrismCoreLaunchRequest.requireAudio`.
public struct PrismCoreSilentStream: Error {
    public init() {}
}

/// What the app wants from a PrismCore session. Everything app-specific
/// (user settings, the server's media-source model, the choice of stream
/// reader) is decided by the caller and handed over as plain values, so this
/// target has no dependency on the app's own packages.
public struct PrismCoreLaunchRequest {
    public var sourceURL: URL
    public var forceMuxedShape: Bool
    public var preferredAudioLanguage: String?
    /// Pass a language only when subtitles are meant to be on: the matching
    /// rendition is marked DEFAULT, so a language passed while subtitles are
    /// off would turn them on unasked.
    public var preferredSubtitleLanguage: String?
    /// `true` forces AC-3 and E-AC-3 through the audio bridge instead of
    /// stream-copying them. A raw multichannel bitstream comes out as
    /// distorted noise on any output path without a receiver to decode it,
    /// on Apple TV as well as iPhone.
    public var bridgeAC3Family: Bool
    /// Throw `PrismCoreSilentStream` when the source has audio tracks and the
    /// session carries none of them. A stream that can go to the server's own
    /// transcode asks for it, so that the film has its sound; a downloaded
    /// file has no such second way and plays silent rather than not at all.
    public var requireAudio: Bool
    /// Who reads the bytes. `nil` leaves it to FFmpeg (plain http, local files).
    public var input: PrismCoreInputFactory?
    /// The library default (20 s) was too tight for a 65 GB remux over a
    /// remote link: PrismCore was working, not stuck, and needed longer to
    /// fetch enough of the source to produce a first segment.
    public var startupTimeout: Duration
    /// A fresh top-level start is always a genuinely new playback attempt (a
    /// new item, a new episode, a first start) and begins a new log session.
    /// A session started again after one died adds to the log of the attempt
    /// it follows, under its own tag: starting a fresh file would throw away
    /// the very lines that say why the first died.
    public var startsNewLog: Bool
    /// Groups this attempt's log lines ("initial", "fallback-1", …).
    public var tag: String
    /// How closely the served playlist is looked at once the session is up.
    public var diagnostics: PlaylistDiagnostics.Depth
    /// `true`: the launch returns after the diagnostics are written (they
    /// read the first segment, so this adds a moment). `false`: they run on
    /// their own and the launch returns at once.
    public var awaitDiagnostics: Bool
    /// How a binary body of the served stream is shown in the log (an MP4 box outline).
    public var describeBinary: (@Sendable (Data) -> String)?
    /// Called as soon as the session exists, before it starts - the place to
    /// register anything that must know the session from its first byte.
    public var onSessionBuilt: (@MainActor (PrismCoreSession) -> Void)?

    public init(
        sourceURL: URL,
        forceMuxedShape: Bool = false,
        preferredAudioLanguage: String? = nil,
        preferredSubtitleLanguage: String? = nil,
        bridgeAC3Family: Bool = true,
        requireAudio: Bool = false,
        input: PrismCoreInputFactory? = nil,
        startupTimeout: Duration = .seconds(45),
        startsNewLog: Bool = true,
        tag: String = "initial",
        diagnostics: PlaylistDiagnostics.Depth = .full,
        awaitDiagnostics: Bool = true,
        describeBinary: (@Sendable (Data) -> String)? = nil,
        onSessionBuilt: (@MainActor (PrismCoreSession) -> Void)? = nil
    ) {
        self.sourceURL = sourceURL
        self.forceMuxedShape = forceMuxedShape
        self.preferredAudioLanguage = preferredAudioLanguage
        self.preferredSubtitleLanguage = preferredSubtitleLanguage
        self.bridgeAC3Family = bridgeAC3Family
        self.requireAudio = requireAudio
        self.input = input
        self.startupTimeout = startupTimeout
        self.startsNewLog = startsNewLog
        self.tag = tag
        self.diagnostics = diagnostics
        self.awaitDiagnostics = awaitDiagnostics
        self.describeBinary = describeBinary
        self.onSessionBuilt = onSessionBuilt
    }
}

public struct PrismCoreLaunch {
    public let playlistURL: URL
    public let session: PrismCoreSession
    /// Embedded subtitle tracks in the order of `session.subtitleRenditions`.
    /// The rendition list carries no stream index, and a cue handed back by
    /// the session is only useful once matched to the language and forced
    /// flag the viewer picked.
    public let subtitleTracks: [PrismCore.SubtitleTrackInfo]
    /// Chapters read off the source itself. Server metadata only has them
    /// when its own scan happened to extract them.
    public let chapters: [PrismCore.ChapterInfo]
}

/// Builds, starts and (on failure) tears down one PrismCore session. This is
/// the part of `PrismCorePlayback.resolve` that was identical on iPhone and
/// Apple TV; the display handshake is separate (see `DisplayCoordinating`).
///
/// Routes a source through PrismCore - a local, on-device remux (FFmpeg
/// demuxes, AVPlayer plays) - instead of asking the Jellyfin server to package
/// it. This is what preserves Dolby Vision/HDR and passthrough-worthy audio:
/// the server's own "copy video, transcode incompatible audio" HLS path
/// hardcodes MPEG-TS segments regardless of what container the client asks
/// for, and Apple's HLS spec requires fMP4 for HEVC - a confirmed, unfixed
/// server bug (jellyfin/jellyfin#18018) that showed up as a black screen.
/// PrismCore fetches the same bytes the app's own Direct Play endpoint serves,
/// demuxes and remuxes them locally into fMP4-HLS on a loopback server, and
/// hands AVPlayer a normal-looking playlist URL. Video is always a stream
/// copy; incompatible audio (TrueHD, DTS, DTS-HD MA, …) goes through
/// PrismCore's audio bridge instead of the server's broken remux path.
@MainActor
public enum PrismCoreLauncher {
    public static func launch(_ request: PrismCoreLaunchRequest, log: KenshoLog) async throws -> PrismCoreLaunch {
        let tag = request.tag
        if request.startsNewLog { log.beginSession(tag: tag) }
        log.log("source: \(LogRedaction.address(request.sourceURL))", tag: tag)
        #if canImport(UIKit)
        // PrismCore's DisplayCapabilities.current() reads exactly these two APIs internally to decide whether it may offer a PQ/Dolby Vision
        // variant at all - logging them here is the only way to see, from outside PrismCore, whether this device reports itself as
        // HDR-capable at the moment a session is built.
        log.log("AVPlayer.availableHDRModes=\(AVPlayer.availableHDRModes) currentEDRHeadroom=\(UIScreen.main.currentEDRHeadroom)", tag: tag)
        #endif

        let session = try PrismCoreSession.readingCurrentDisplay(
            url: request.sourceURL,
            forceMuxedShape: request.forceMuxedShape,
            preferredAudioLanguage: request.preferredAudioLanguage,
            preferredSubtitleLanguage: request.preferredSubtitleLanguage,
            input: request.input,
            // Reachability stays loopback-only: AirPlay opts into the
            // network-visible variant separately, for the duration of the
            // route, and sessions that never AirPlay should never enable it.
            forcedAudioBridgeCodecs: request.bridgeAC3Family ? [AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3] : []
        )
        request.onSessionBuilt?(session)

        // Must be registered before start(). Also the only way to learn the
        // embedded subtitle tracks' real container stream indices.
        var subtitleTracksTask: Task<[PrismCore.SubtitleTrackInfo], Never>?
        if let checkpoints = try? await session.startupCheckpoints() {
            subtitleTracksTask = consumeStartupCheckpoints(checkpoints, log: log, tag: tag)
        }

        do {
            let playlist = try await session.start(startupTimeout: request.startupTimeout)
            // What became of each audio track - the first thing to read when a film plays without sound. (A forced AC-3/E-AC-3 track was
            // once left out for good and the log only said `index.m3u8` instead of `master.m3u8`: silent video, found on the Apple TV.)
            log.log("audio: \(audioRoutes(of: session)), the player gets \(playlist.lastPathComponent)", tag: tag)
            if request.requireAudio, session.audioDelivery == .unavailable { throw PrismCoreSilentStream() }
            let depth = request.diagnostics, describeBinary = request.describeBinary
            if request.awaitDiagnostics {
                await PlaylistDiagnostics.run(playlist: playlist, log: log, tag: tag, depth: depth, describeBinary: describeBinary)
            } else {
                Task { await PlaylistDiagnostics.run(playlist: playlist, log: log, tag: tag, depth: depth, describeBinary: describeBinary) }
            }
            let subtitleTracks = await subtitleTracksTask?.value ?? []
            return PrismCoreLaunch(
                playlistURL: playlist,
                session: session,
                subtitleTracks: subtitleTracks,
                chapters: await session.chapters
            )
        } catch {
            // start() throwing leaves its producer thread and loopback
            // server running; only stop() tears them down, and it is safe on
            // a session that never finished starting. Skipping this leaks a
            // thread, an HTTP listener and a work directory per failed attempt.
            await session.stop()
            throw error
        }
    }

    /// "#1 copied, #2 bridged", or the fact that there is no audio at all.
    static func audioRoutes(of session: PrismCoreSession) -> String {
        let deliveries = session.audioTrackDeliveries
        return deliveries.isEmpty ? "no audio track in the source" : deliveries.map { "#\($0.streamIndex) \($0.delivery.rawValue)" }.joined(separator: ", ")
    }

    /// Logs every startup checkpoint as it arrives and remembers the embedded
    /// subtitle tracks off `.streamInfoResolved`. Public because fallback
    /// tiers build their session directly against `PrismCoreSession` and
    /// need the identical capture.
    public nonisolated static func consumeStartupCheckpoints(
        _ checkpoints: AsyncStream<PrismCore.StartupCheckpoint>,
        log: KenshoLog,
        tag: String
    ) -> Task<[PrismCore.SubtitleTrackInfo], Never> {
        Task {
            var subtitleTracks: [PrismCore.SubtitleTrackInfo] = []
            for await mark in checkpoints {
                log.log("startup \(mark.elapsed): \(mark.phase)", tag: tag)
                if case .streamInfoResolved(let info) = mark.phase {
                    subtitleTracks = info.subtitleTracks
                }
            }
            return subtitleTracks
        }
    }
}
