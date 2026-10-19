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
///
/// The address of a request carries the account's access token in its query (a Jellyfin stream is asked for with `api_key=`), and the comment of an
/// error may carry an address of its own: both go through `LogRedaction.text`, because the log is shared for diagnosis.
public enum PlayerItemLogDump {
    public static func dump(_ item: AVPlayerItem, log: KenshoLog, tag: String) {
        if let events = item.errorLog()?.events, !events.isEmpty {
            log.log("errorLog: \(events.count) event(s)", tag: tag)
            for (i, e) in events.enumerated() {
                log.log(errorLine(index: i, date: e.date?.description, uri: e.uri, server: e.serverAddress, statusCode: e.errorStatusCode, domain: e.errorDomain, comment: e.errorComment), tag: tag)
            }
        } else {
            log.log("errorLog: empty", tag: tag)
        }
        if let events = item.accessLog()?.events, !events.isEmpty {
            log.log("accessLog: \(events.count) event(s)", tag: tag)
            for (i, e) in events.enumerated() {
                log.log(accessLine(index: i, uri: e.uri, requests: e.numberOfMediaRequests, bytes: e.numberOfBytesTransferred, duration: e.transferDuration,
                                   observedBitrate: e.observedBitrate, indicatedBitrate: e.indicatedBitrate, switchBitrate: e.switchBitrate, playbackType: e.playbackType), tag: tag)
            }
        } else {
            log.log("accessLog: empty", tag: tag)
        }
    }

    /// One event of the error log as a line. (Apart from the redaction, the line is what the app's own log wrote before there was a Kensho.)
    static func errorLine(index: Int, date: String?, uri: String?, server: String?, statusCode: Int, domain: String, comment: String?) -> String {
        "  [\(index)] date=\(date ?? "?") uri=\(LogRedaction.text(uri ?? "?")) server=\(LogRedaction.text(server ?? "?")) statusCode=\(statusCode) domain=\(domain) comment=\(LogRedaction.text(comment ?? "?"))"
    }

    /// One event of the access log as a line.
    static func accessLine(index: Int, uri: String?, requests: Int, bytes: Int64, duration: TimeInterval, observedBitrate: Double, indicatedBitrate: Double, switchBitrate: Double, playbackType: String?) -> String {
        "  [\(index)] uri=\(LogRedaction.text(uri ?? "?")) requests=\(requests) bytes=\(bytes) duration=\(duration) observedBitrate=\(observedBitrate) indicatedBitrate=\(indicatedBitrate) switchBitrate=\(switchBitrate) playbackType=\(playbackType ?? "?")"
    }
}
