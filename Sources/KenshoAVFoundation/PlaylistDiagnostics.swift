import Foundation
import AVFoundation
import Kensho

/// Content-level checks against a freshly served playlist, so a failed start
/// leaves evidence of where the chain broke (loopback server, playlist,
/// init segment, first media segment, or AVFoundation's own verdict) instead
/// of only "it did not play".
///
/// The iPhone's `PrismCorePlayback.runDiagnostics`, moved here so that the Apple
/// TV (which had two bare `print` probes) reads the same way.
public enum PlaylistDiagnostics {
    public enum Depth: Sendable {
        /// The whole chain: master, media playlist, init segment, first media
        /// segment, a Range request, and AVFoundation's verdict. The first
        /// segment is read whole - a few MB for 1080p, tens of MB for a 4K remux.
        case full
        /// The playlist itself and AVFoundation's verdict. Nothing is read
        /// that the player will not read anyway.
        case light
    }

    /// - Parameter describeBinary: how a binary body (an init or media segment)
    ///   is shown in the log - the app passes its MP4 box outline. `nil` logs
    ///   only status and size.
    public static func run(
        playlist: URL,
        log: KenshoLog,
        tag: String,
        depth: Depth = .full,
        describeBinary: (@Sendable (Data) -> String)? = nil
    ) async {
        switch depth {
        case .full:
            await probeGraph(from: playlist, depth: 0, kind: "", log: log, tag: tag, describeBinary: describeBinary)
            await probeRange(playlist: playlist, log: log, tag: tag)
        case .light:
            await probeReachable(playlist: playlist, log: log, tag: tag)
        }
        await probePlayable(playlist: playlist, log: log, tag: tag)
    }

    /// A plain `URLSession` fetch of the exact URL the player is about to be
    /// handed, using the app's ordinary networking instead of AVPlayer's own
    /// loading. If this succeeds while AVPlayer still never buffers anything,
    /// the fault is in AVPlayer's path to the loopback server, not in the
    /// server's reachability or health.
    static func probeReachable(playlist: URL, log: KenshoLog, tag: String) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: playlist)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            log.log("loopback probe: OK status=\(status) bytes=\(data.count)", tag: tag)
        } catch {
            log.log("loopback probe: FAILED \(error)", tag: tag)
        }
    }

    /// AVFoundation's own HTTP loading for fMP4 routinely issues Range
    /// requests (fast-start moov reads, seek support). Confirmed PrismCore's
    /// LoopbackHTTPServer once ignored them (always 200 + full body,
    /// Accept-Ranges: none); patched to real 206 support, and AVPlayer failed
    /// identically regardless. Kept as a standing regression check.
    static func probeRange(playlist: URL, log: KenshoLog, tag: String) async {
        let initURL = playlist.deletingLastPathComponent().appendingPathComponent("init.mp4")
        var request = URLRequest(url: initURL)
        request.setValue("bytes=0-127", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let contentRange = http?.value(forHTTPHeaderField: "Content-Range") ?? "(none)"
            let acceptRanges = http?.value(forHTTPHeaderField: "Accept-Ranges") ?? "(none)"
            let contentLength = http?.value(forHTTPHeaderField: "Content-Length") ?? "(none)"
            // 200 with the whole file is a legitimate answer to a Range request (HTTP lets a server ignore it) and nothing AVPlayer trips over for
            // an init segment that is a few hundred bytes; it would matter for a playlist of #EXT-X-BYTERANGE pieces, which this never serves.
            let verdict: String
            switch status {
            case 206: verdict = "✓ honored"
            case 200: verdict = "ℹ️ ignored (the whole file came back, which HTTP allows)"
            default: verdict = "⚠️ unexpected status (requested 128 bytes)"
            }
            log.log("Range probe: status=\(status) bytes-returned=\(data.count) Content-Range=\(contentRange) Accept-Ranges=\(acceptRanges) Content-Length=\(contentLength) \(verdict)", tag: tag)
        } catch {
            log.log("Range probe FAILED \(error)", tag: tag)
        }
    }

    /// Asks AVFoundation itself, via the same AVURLAsset machinery
    /// AVPlayerItem(url:) builds internally, whether it recognizes this
    /// URL/content as a playable format at all (codec/container/MIME-type
    /// registration) *before* any content-graph validation (HDR claims, audio
    /// rendition declarations) runs. A `false`/thrown result would mean
    /// AVFoundation never got past recognizing the format - pointing at the
    /// .m3u8/MIME-type registration itself rather than at a specific declared
    /// claim being refused.
    static func probePlayable(playlist: URL, log: KenshoLog, tag: String) async {
        let asset = AVURLAsset(url: playlist)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            log.log("AVURLAsset probe: isPlayable=\(isPlayable)", tag: tag)
        } catch {
            log.log("AVURLAsset probe: load(.isPlayable) FAILED \(error)", tag: tag)
        }
    }

    /// Fetches `url`, logs its status/byte-count/body (playlists are tiny -
    /// safe to log in full), then follows the first `#EXT-X-STREAM-INF` line
    /// (master → media playlist) or first non-comment segment line to the next
    /// level, up to a master → media playlist → init segment → first media
    /// segment depth of 4. A segment whose byte count looks implausibly small
    /// is flagged explicitly - that shape is what a truncated/not-yet-flushed
    /// file read from the loopback server would look like.
    static func probeGraph(
        from url: URL, depth: Int, kind: String, log: KenshoLog, tag: String,
        describeBinary: (@Sendable (Data) -> String)?
    ) async {
        guard depth < 4 else { return }
        let t = Date().timeIntervalSinceReferenceDate
        let label = "HLS probe t=\(t) depth=\(depth)\(kind.isEmpty ? "" : " (\(kind))") \(url.lastPathComponent)"
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "?"
            log.log("\(label) status=\(status) bytes=\(data.count) content-type=\(contentType)", tag: tag)
            guard let text = String(data: data, encoding: .utf8) else {
                // Small is the nature of an init segment (a few hundred bytes of configuration); only a MEDIA segment of a few KB looks like a
                // truncated read.
                let suspicious = kind != "init-segment" && data.count < 4096
                log.log("\(label) — binary, \(data.count) bytes\(suspicious ? " ⚠️ suspiciously small" : "")", tag: tag)
                if let describeBinary { log.log("\(label) MP4 boxes: \(describeBinary(data))", tag: tag) }
                return
            }
            log.log("\(label) body:\n\(text)", tag: tag)
            let lines = text.split(separator: "\n")
            // The exact CODECS/SUPPLEMENTAL-CODECS declaration is the single most decision-relevant line in a master playlist for chasing
            // -16170 specifically - called out on its own line since it's otherwise buried inside the full body dump above.
            if let streamInf = lines.first(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
                log.log("\(label) STREAM-INF: \(streamInf)", tag: tag)
            }
            let segments = lines.filter { $0.hasPrefix("#EXTINF:") }.count
            if segments > 0 { log.log("\(label) segment count declared: \(segments)", tag: tag) }
            // #EXT-X-MAP:URI="init.mp4" - the fMP4 initialization segment (moov box: codec configs, including PrismCore's hand-patched
            // dvcC/dvvC Dolby Vision and dec3 EAC3-JOC boxes). Every media segment on this playlist depends on it; it starts with '#' like
            // every other tag, so a probe that only follows plain lines skips it.
            if let map = lines.first(where: { $0.hasPrefix("#EXT-X-MAP:") }),
               let open = map.range(of: "URI=\""),
               let close = map[open.upperBound...].firstIndex(of: "\""),
               let mapURL = URL(string: String(map[open.upperBound..<close]), relativeTo: url)?.absoluteURL {
                await probeGraph(from: mapURL, depth: depth + 1, kind: "init-segment", log: log, tag: tag, describeBinary: describeBinary)
            }
            guard let next = lines.first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  let nextURL = URL(string: String(next), relativeTo: url)?.absoluteURL else { return }
            await probeGraph(from: nextURL, depth: depth + 1, kind: next.hasSuffix(".m3u8") ? "media-playlist" : "first-segment", log: log, tag: tag, describeBinary: describeBinary)
        } catch {
            log.log("\(label) FAILED \(error)", tag: tag)
        }
    }
}
