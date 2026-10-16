import Foundation
import Kensho
import PrismCore
import Libavcodec

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
    /// Who reads the bytes. `nil` leaves it to FFmpeg (plain http, local files).
    public var input: PrismCoreInputFactory?
    /// The library default (20 s) was too tight for a 65 GB remux over a
    /// remote link: PrismCore was working, not stuck, and needed longer to
    /// fetch enough of the source to produce a first segment.
    public var startupTimeout: Duration
    /// Groups this attempt's log lines ("initial", "fallback-1", …).
    public var tag: String

    public init(
        sourceURL: URL,
        forceMuxedShape: Bool = false,
        preferredAudioLanguage: String? = nil,
        preferredSubtitleLanguage: String? = nil,
        bridgeAC3Family: Bool = true,
        input: PrismCoreInputFactory? = nil,
        startupTimeout: Duration = .seconds(45),
        tag: String = "initial"
    ) {
        self.sourceURL = sourceURL
        self.forceMuxedShape = forceMuxedShape
        self.preferredAudioLanguage = preferredAudioLanguage
        self.preferredSubtitleLanguage = preferredSubtitleLanguage
        self.bridgeAC3Family = bridgeAC3Family
        self.input = input
        self.startupTimeout = startupTimeout
        self.tag = tag
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
@MainActor
public enum PrismCoreLauncher {
    public static func launch(_ request: PrismCoreLaunchRequest, log: KenshoLog) async throws -> PrismCoreLaunch {
        let tag = request.tag
        log.log("source: \(LogRedaction.address(request.sourceURL))", tag: tag)

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

        // Must be registered before start(). Also the only way to learn the
        // embedded subtitle tracks' real container stream indices.
        var subtitleTracksTask: Task<[PrismCore.SubtitleTrackInfo], Never>?
        if let checkpoints = try? await session.startupCheckpoints() {
            subtitleTracksTask = consumeStartupCheckpoints(checkpoints, log: log, tag: tag)
        }

        do {
            let playlist = try await session.start(startupTimeout: request.startupTimeout)
            await PlaylistDiagnostics.run(playlist: playlist, log: log, tag: tag)
            let subtitleTracks = await subtitleTracksTask?.value ?? []
            return PrismCoreLaunch(
                playlistURL: playlist,
                session: session,
                subtitleTracks: subtitleTracks,
                chapters: await session.chapters
            )
        } catch {
            // start() throwing leaves its producer thread and loopback server
            // running; only stop() tears them down, and it is safe on a
            // session that never finished starting. Skipping this leaks a
            // thread, an HTTP listener and a work directory per failed attempt.
            await session.stop()
            throw error
        }
    }

    /// Logs every startup checkpoint as it arrives and remembers the embedded
    /// subtitle tracks off `.streamInfoResolved`. Public because fallback
    /// tiers build their session directly against `PrismCoreSession` and
    /// need the identical capture.
    public static func consumeStartupCheckpoints(
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
