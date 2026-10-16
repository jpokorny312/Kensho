import Foundation

/// Where log lines go. The app decides which sinks exist (file, os.Logger,
/// console); the playback code only talks to `KenshoLog`.
public protocol LogSink: Sendable {
    func write(_ line: String, tag: String)
}

/// One front door for logging. iPhone and Apple TV used to keep separate
/// logs (a diagnostics file on one, a cache file plus `print` on the other),
/// so a failure on one platform could not be read the way the other's was.
public struct KenshoLog: Sendable {
    public var sinks: [any LogSink]

    public init(sinks: [any LogSink]) {
        self.sinks = sinks
    }

    /// `tag` groups the lines of one attempt ("initial", "fallback-1", …) so
    /// a whole fallback chain reads as one document in one file.
    public func log(_ line: String, tag: String = "initial") {
        for sink in sinks { sink.write(line, tag: tag) }
    }
}

public enum LogRedaction {
    /// The address with scheme, host, port and path only. A stream address
    /// carries the access token in its query (and sometimes credentials in
    /// its user info); a log file that is shared for diagnosis must never
    /// contain either.
    public static func address(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "(unparseable address)" }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? "(unparseable address)"
    }
}
