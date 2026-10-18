import Foundation

/// Where log lines go. The app decides which sinks exist (file, os.Logger,
/// console); the playback code only talks to `KenshoLog`.
public protocol LogSink: Sendable {
    func write(_ line: String, tag: String)

    /// A genuinely new playback attempt begins (a new film, a new episode, a
    /// first start). A sink that keeps attempts apart - a file - starts a new
    /// section; one that does not simply ignores it.
    func beginSession(tag: String)
}

public extension LogSink {
    func beginSession(tag: String) {}
}

/// One front door for logging. iPhone and Apple TV used to keep separate
/// logs (a diagnostics file on one, a cache file plus `print` on the other),
/// so a failure on one platform could not be read the way the other's was.
public struct KenshoLog: Sendable {
    public var sinks: [any LogSink]

    public init(sinks: [any LogSink]) {
        self.sinks = sinks
    }

    /// Writes nowhere. For tests and for code that is handed a log it does not need.
    public static let silent = KenshoLog(sinks: [])

    /// `tag` groups the lines of one attempt ("initial", "fallback-1", …) so
    /// a whole fallback chain reads as one document in one file.
    public func log(_ line: String, tag: String = "initial") {
        for sink in sinks { sink.write(line, tag: tag) }
    }

    /// Starts a new section in every sink that keeps them. Fallback tiers and
    /// reconnects of the SAME attempt must not call this: starting over would
    /// push away the very lines that say why the first try died.
    public func beginSession(tag: String = "initial") {
        for sink in sinks { sink.beginSession(tag: tag) }
    }
}

/// The text of one log line - the same on the console and in the file, so
/// what is read in Xcode is what is found in the file afterwards.
public enum LogLine {
    /// `[time] [tag] message`; a line without a tag is `[time] message`.
    public static func format(time: String, tag: String, message: String) -> String {
        "[\(time)]\(tag.isEmpty ? "" : " [\(tag)]") \(message)"
    }
}

/// A sink that prints to the console (Xcode shows it live).
public final class ConsoleLog: LogSink, @unchecked Sendable {
    // `DateFormatter.string(from:)` is safe to call from any thread as long as the
    // formatter is not changed after it is set up.
    private let formatter: DateFormatter

    public init(timestampFormat: String = "HH:mm:ss.SSS") {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timestampFormat
        self.formatter = formatter
    }

    public func write(_ line: String, tag: String) {
        print(LogLine.format(time: formatter.string(from: Date()), tag: tag, message: line))
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
