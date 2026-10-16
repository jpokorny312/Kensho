import Foundation

/// A size-capped log file: when it passes `maximumBytes` it becomes
/// `<name>.1.log` (replacing the previous one) and a new file starts. Writes
/// happen on a private serial queue, so callers on a playback thread never
/// wait on disk.
public final class FileLog: LogSink, @unchecked Sendable {
    public let url: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "Kensho.FileLog")
    // DateFormatter is not thread-safe; it is only touched on `queue`.
    private let formatter: DateFormatter

    public init(url: URL, maximumBytes: Int = 256 * 1024) {
        self.url = url
        self.maximumBytes = maximumBytes
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = formatter
    }

    public func write(_ line: String, tag: String) {
        let now = Date()
        queue.async { [self] in
            let stamped = "[\(formatter.string(from: now))] [\(tag)] \(line)\n"
            append(stamped)
        }
    }

    /// Starts a fresh file for a genuinely new playback attempt. Fallback
    /// tiers and reconnects must not call this: starting over would throw
    /// away the very lines that say why the first attempt died.
    public func beginSession(tag: String) {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: url)
        }
        write("log file: \(url.path)", tag: tag)
    }

    /// Blocks until every line written so far is on disk. For tests and for
    /// sharing the file.
    public func flush() {
        queue.sync {}
    }

    private func append(_ text: String) {
        let files = FileManager.default
        if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maximumBytes {
            let older = url.deletingPathExtension().appendingPathExtension("1.log")
            try? files.removeItem(at: older)
            try? files.moveItem(at: url, to: older)
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
