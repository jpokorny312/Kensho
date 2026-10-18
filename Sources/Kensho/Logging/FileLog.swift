import Foundation

/// The diagnostics file of an app: one section ("session") per playback
/// attempt, and the sessions before it kept next to it (`name.1.log` is the
/// one before, `name.2.log` the one before that, …).
///
/// Why sessions are kept and not overwritten: the start of the next episode,
/// a minute after a failure, used to wipe the only record of that failure.
/// Fallback tiers and reconnects of the SAME attempt only append, so a whole
/// fallback chain reads as one document.
///
/// Writes happen on a private serial queue, so callers on a playback thread
/// never wait on disk.
public final class FileLog: LogSink, @unchecked Sendable {
    public let url: URL

    /// A session that grows past this loses its OLDEST lines (the failure that
    /// is being chased is at the end, not at the start). Never reached by an
    /// ordinary film; it only stops a runaway loop from filling the disk.
    private let maximumBytes: Int
    /// How many sessions are kept next to the current one.
    private let keptSessions: Int
    /// A session smaller than this (opened and closed again at once) is not
    /// worth a place among the kept ones.
    private let smallestKeptSession: Int
    private let sessionTitle: String
    private let queue = DispatchQueue(label: "Kensho.FileLog")
    // DateFormatter is only touched on `queue`.
    private let formatter: DateFormatter
    // Only touched on `queue`: the size of the current file, so that a line does not cost a `stat`.
    private var knownSize: Int?

    public init(
        url: URL,
        maximumBytes: Int = 4 * 1024 * 1024,
        keptSessions: Int = 3,
        smallestKeptSession: Int = 2_000,
        timestampFormat: String = "HH:mm:ss.SSS",
        sessionTitle: String = "diagnostic session"
    ) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.keptSessions = keptSessions
        self.smallestKeptSession = smallestKeptSession
        self.sessionTitle = sessionTitle
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timestampFormat
        self.formatter = formatter
    }

    public func write(_ line: String, tag: String) {
        let now = Date()
        queue.async { [self] in
            append(LogLine.format(time: formatter.string(from: now), tag: tag, message: line) + "\n")
        }
    }

    /// Starts a fresh file for a genuinely new playback attempt; the file of
    /// the attempt before it moves one place down the line of kept sessions.
    /// Fallback tiers and reconnects must not call this.
    ///
    /// Returns when the new file is in place (the caller may read the kept
    /// sessions right after).
    public func beginSession(tag: String) {
        let now = Date()
        queue.sync { [self] in
            rotateSessions()
            let header = "=== \(sessionTitle): \(tag) — \(now) ===\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
            knownSize = header.utf8.count
        }
        write("session begin", tag: tag)
        // Where to find it is the whole point of keeping it: Settings → Share Diagnostic Log, or `devicectl device copy from`.
        write("log file: \(url.path)", tag: tag)
    }

    /// The files of the sessions before the current one, the latest first
    /// (only those that exist).
    public var previousSessionURLs: [URL] {
        guard keptSessions > 0 else { return [] }
        return (1...keptSessions).map { sessionURL(age: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Blocks until every line written so far is on disk. For tests and for
    /// sharing the file.
    public func flush() {
        queue.sync {}
    }

    // MARK: - On `queue`

    private func sessionURL(age: Int) -> URL {
        guard age > 0 else { return url }
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(name).\(age).\(url.pathExtension.isEmpty ? "log" : url.pathExtension)")
    }

    /// Moves every session one place back and the current file to the first place.
    private func rotateSessions() {
        let files = FileManager.default
        let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard keptSessions > 0, size >= smallestKeptSession else { return }
        try? files.removeItem(at: sessionURL(age: keptSessions))
        for age in stride(from: keptSessions - 1, through: 0, by: -1) {
            try? files.moveItem(at: sessionURL(age: age), to: sessionURL(age: age + 1))
        }
        knownSize = 0
    }

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        var size = knownSize ?? ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0)
        if size + data.count > maximumBytes { size = dropOldestLines() }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        knownSize = size + data.count
    }

    /// Keeps the newest half of the file, starting at a line, behind a note
    /// that lines are missing. Returns the new size.
    private func dropOldestLines() -> Int {
        guard let current = try? Data(contentsOf: url) else { return 0 }
        let keep = current.suffix(maximumBytes / 2)
        let tail = keep.firstIndex(of: 0x0A).map { keep.suffix(from: $0 + 1) } ?? keep
        var rewritten = Data("[… the oldest lines of this session were dropped to keep the file small]\n".utf8)
        rewritten.append(tail)
        try? rewritten.write(to: url, options: .atomic)
        return rewritten.count
    }
}
