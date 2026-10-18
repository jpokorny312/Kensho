import Foundation
import AVFoundation
import Kensho

/// AVPlayerItem's own network-transport diagnostics. `errorLog()` records
/// failed HTTP/loading events (status code, URI, server address, a free-text
/// comment) independent of whatever bubbles up to `.status`/`.error` -
/// AVFoundation's *own* record of what it actually requested and what came
/// back over the wire, a different (and likely more specific) vantage point
/// than a side URLSession probe racing the same server can offer, since it's
/// the real request. `accessLog()` records every request that *did* succeed
/// (bytes transferred, duration, bitrate) - useful to see how far AVPlayer got
/// before whatever request produced the failure.
public enum PlayerItemLogDump {
    public static func dump(_ item: AVPlayerItem, log: KenshoLog, tag: String) {
        if let events = item.errorLog()?.events, !events.isEmpty {
            log.log("errorLog: \(events.count) event(s)", tag: tag)
            for (i, e) in events.enumerated() {
                log.log("  [\(i)] date=\(e.date?.description ?? "?") uri=\(e.uri ?? "?") server=\(e.serverAddress ?? "?") statusCode=\(e.errorStatusCode) domain=\(e.errorDomain) comment=\(e.errorComment ?? "?")", tag: tag)
            }
        } else {
            log.log("errorLog: empty", tag: tag)
        }
        if let events = item.accessLog()?.events, !events.isEmpty {
            log.log("accessLog: \(events.count) event(s)", tag: tag)
            for (i, e) in events.enumerated() {
                log.log("  [\(i)] uri=\(e.uri ?? "?") requests=\(e.numberOfMediaRequests) bytes=\(e.numberOfBytesTransferred) duration=\(e.transferDuration) observedBitrate=\(e.observedBitrate) indicatedBitrate=\(e.indicatedBitrate) switchBitrate=\(e.switchBitrate) playbackType=\(e.playbackType ?? "?")", tag: tag)
            }
        } else {
            log.log("accessLog: empty", tag: tag)
        }
    }
}
