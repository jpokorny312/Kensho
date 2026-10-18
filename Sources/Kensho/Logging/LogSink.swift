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

    /// `text` with every web address in it cut down as `address` does, and a token named as one (`api_key=`, `X-Emby-Token:`, ...) hidden wherever it
    /// stands. An error carries the address that failed along - in its description, in its `userInfo` - and the address of a stream carries the
    /// access token: an error written out for a log must not bring it into the file, which is shared for diagnosis.
    public static func text(_ text: String) -> String {
        var result = text
        if result.contains("://"), let expression = try? NSRegularExpression(pattern: #"https?://[^\s"'<>\)\]]+"#) {
            var cut = ""
            var last = result.startIndex
            let length = (result as NSString).length
            for match in expression.matches(in: result, range: NSRange(location: 0, length: length)) {
                guard let range = Range(match.range, in: result) else { continue }
                cut += result[last..<range.lowerBound]
                var found = String(result[range])
                // (A full stop or a comma after the address belongs to the sentence.)
                var tail = ""
                while let end = found.last, ".,;:!?".contains(end) {
                    tail.insert(end, at: tail.startIndex)
                    found.removeLast()
                }
                cut += (URL(string: found).map(address) ?? cutByHand(found)) + tail
                last = range.upperBound
            }
            cut += result[last...]
            result = cut
        }
        if let named = try? NSRegularExpression(pattern: #"(?i)\b(api_?key|access_?token|x-emby-token|token|authorization)(\s*[=:]\s*)[^\s&"',;]+"#) {
            result = named.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "$1$2<hidden>")
        }
        return result
    }

    /// An address that `URL` will not take, cut at its query and fragment and without what stands before an `@` in it.
    private static func cutByHand(_ address: String) -> String {
        var cut = String(address.prefix { $0 != "?" && $0 != "#" })
        if let scheme = cut.range(of: "://"), let at = cut.lastIndex(of: "@"), at > scheme.upperBound,
           !cut[scheme.upperBound..<at].contains("/") {
            cut.removeSubrange(scheme.upperBound...at)
        }
        return cut
    }
}
