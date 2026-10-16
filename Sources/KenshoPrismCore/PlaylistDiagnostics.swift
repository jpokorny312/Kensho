import Foundation
import AVFoundation
import Kensho

/// Content-level checks against a freshly served playlist, so a failed start
/// leaves evidence of where the chain broke (loopback server, playlist,
/// init segment, first media segment, or AVFoundation's own verdict) instead
/// of only "it did not play".
///
/// Ported from the iPhone's `PrismCorePlayback.runDiagnostics`; the Apple TV
/// had only two bare `print` probes. The init-segment box outline
/// (`MP4BoxOutline`) is not ported yet: it lives in the app.
public enum PlaylistDiagnostics {
    public static func run(playlist: URL, log: KenshoLog, tag: String) async {
        await probeGraph(from: playlist, depth: 0, kind: "", log: log, tag: tag)
        await probeRange(playlist: playlist, log: log, tag: tag)
        await probePlayable(playlist: playlist, log: log, tag: tag)
    }

    /// AVFoundation's HTTP loading for fMP4 routinely issues Range requests.
    /// A server that ignores one (200 with the whole body) is legal HTTP and
    /// harmless for an init segment of a few hundred bytes; it would matter
    /// for #EXT-X-BYTERANGE playlists, which are never served.
    private static func probeRange(playlist: URL, log: KenshoLog, tag: String) async {
        let initURL = playlist.deletingLastPathComponent().appendingPathComponent("init.mp4")
        var request = URLRequest(url: initURL)
        request.setValue("bytes=0-127", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let verdict: String
            switch status {
            case 206: verdict = "honored"
            case 200: verdict = "ignored (whole file came back, which HTTP allows)"
            default: verdict = "UNEXPECTED status (requested 128 bytes)"
            }
            log.log("Range probe: status=\(status) bytes=\(data.count) Content-Range=\(http?.value(forHTTPHeaderField: "Content-Range") ?? "(none)") \(verdict)", tag: tag)
        } catch {
            log.log("Range probe FAILED \(error)", tag: tag)
        }
    }

    /// Asks AVFoundation whether it recognizes the URL as a playable format
    /// at all, before any content validation (HDR claims, audio renditions)
    /// runs. `false` or a throw would point at format registration itself.
    private static func probePlayable(playlist: URL, log: KenshoLog, tag: String) async {
        let asset = AVURLAsset(url: playlist)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            log.log("AVURLAsset probe: isPlayable=\(isPlayable)", tag: tag)
        } catch {
            log.log("AVURLAsset probe: load(.isPlayable) FAILED \(error)", tag: tag)
        }
    }

    /// Follows master → media playlist → init segment → first media segment
    /// (depth ≤ 4), logging status and size at each step. Playlists are tiny,
    /// so their bodies are logged whole.
    private static func probeGraph(from url: URL, depth: Int, kind: String, log: KenshoLog, tag: String) async {
        guard depth < 4 else { return }
        let label = "HLS probe depth=\(depth)\(kind.isEmpty ? "" : " (\(kind))") \(url.lastPathComponent)"
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let http = response as? HTTPURLResponse
            log.log("\(label) status=\(http?.statusCode ?? -1) bytes=\(data.count) content-type=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "?")", tag: tag)
            guard let text = String(data: data, encoding: .utf8) else {
                // An init segment is a few hundred bytes by nature; only a
                // MEDIA segment this small looks like a truncated read from
                // the loopback server.
                let suspicious = kind != "init-segment" && data.count < 4096
                log.log("\(label) binary, \(data.count) bytes\(suspicious ? " SUSPICIOUSLY SMALL" : "")", tag: tag)
                return
            }
            log.log("\(label) body:\n\(text)", tag: tag)
            let lines = text.split(separator: "\n")
            // The CODECS / SUPPLEMENTAL-CODECS declaration is the most
            // decision-relevant line in a master playlist when chasing -16170.
            if let streamInf = lines.first(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
                log.log("\(label) STREAM-INF: \(streamInf)", tag: tag)
            }
            let segments = lines.filter { $0.hasPrefix("#EXTINF:") }.count
            if segments > 0 { log.log("\(label) segment count declared: \(segments)", tag: tag) }
            // The fMP4 init segment starts with '#EXT-X-MAP', like every
            // other tag, so a probe that only follows plain lines skips it.
            if let map = lines.first(where: { $0.hasPrefix("#EXT-X-MAP:") }),
               let open = map.range(of: "URI=\""),
               let close = map[open.upperBound...].firstIndex(of: "\""),
               let mapURL = URL(string: String(map[open.upperBound..<close]), relativeTo: url)?.absoluteURL {
                await probeGraph(from: mapURL, depth: depth + 1, kind: "init-segment", log: log, tag: tag)
            }
            guard let next = lines.first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  let nextURL = URL(string: String(next), relativeTo: url)?.absoluteURL else { return }
            await probeGraph(from: nextURL, depth: depth + 1, kind: next.hasSuffix(".m3u8") ? "media-playlist" : "first-segment", log: log, tag: tag)
        } catch {
            log.log("\(label) FAILED \(error)", tag: tag)
        }
    }
}
