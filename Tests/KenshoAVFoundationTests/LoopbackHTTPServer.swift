import Foundation
import Network

/// A small HTTP/1.1 server on 127.0.0.1 for the tests that need a stream to come over HTTP, as it does to the apps: `AVPlayer` asks for playlists and
/// segments one request at a time, and what it does when an answer does not come (a stall) or a part is not loaded (a jump) can only be seen when the
/// answer is a test's to give. (A file on disk answers at once and always; `AVAssetResourceLoader` tricks changed what the player did with the source.)
///
/// What a test can do with it: serve bytes at a path, **hold** a path - the request is kept open and answered when the test **releases** it - and read
/// the requests that were made, in order. One request to a connection (`Connection: close`), no keep-alive, no TLS, no chunked bodies: the least that
/// `AVPlayer` takes. Everything runs on one serial queue; the methods may be called from any thread.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Resource {
        var contentType: String
        var body: Data
    }

    struct Request: Equatable {
        /// The request target as the client sent it (path and query).
        var target: String
        var path: String
        var range: String?
        /// `ProcessInfo.systemUptime` when the request was read.
        var at: TimeInterval
    }

    private struct Parked {
        var connection: NWConnection
        var request: Request
        var isHead: Bool
    }

    private let queue = DispatchQueue(label: "kensho.tests.loopback-http")
    private let listener: NWListener
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var resources: [String: Resource] = [:]
    private var held: Set<String> = []
    private var failing: [String: Int] = [:]
    private var parked: [Parked] = []
    private var log: [Request] = []
    private var answered: [Request] = []

    /// The port the server listens on; valid after `start()`.
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        // Loopback only: a test must not open a port to the network it runs on.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    deinit {
        // (Not `stop()`: the last reference can be given up on the server's own queue, and `sync` on it from there never returns.)
        listener.cancel()
        for connection in connections.values { connection.cancel() }
    }

    /// Binds a port (the system picks it) and starts to accept.
    func start() async throws {
        // (The state handler runs on the server's queue, one call at a time; the compiler cannot know, so the flag is a reference.)
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    self.port = self.listener.port?.rawValue ?? 0
                    continuation.resume()
                case let .failed(error):
                    once.done = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    once.done = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    /// Ends the server; requests that wait are dropped.
    func stop() {
        listener.cancel()
        queue.sync {
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            parked.removeAll()
        }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    // MARK: - What the server has

    func serve(_ body: Data, at path: String, contentType: String) {
        queue.sync { resources[path] = Resource(contentType: contentType, body: body) }
    }

    /// From now on `path` is answered with this status (and no body worth the name) instead of its resource: a segment that is gone, a server that broke.
    func fail(_ path: String, status: Int = 404) {
        queue.sync { failing[path] = status }
    }

    /// From now on a request for `path` is read and kept open until `release(_:)`.
    func hold(_ path: String) {
        queue.sync { _ = held.insert(path) }
    }

    /// Answers the requests that are waiting for `path`, and every later one at once.
    func release(_ path: String) {
        queue.sync {
            held.remove(path)
            let waiting = parked.filter { $0.request.path == path }
            parked.removeAll { $0.request.path == path }
            for entry in waiting { respond(to: entry.connection, request: entry.request, isHead: entry.isHead) }
        }
    }

    // MARK: - What the clients asked

    /// Every request that was read, in order, held ones included.
    var requests: [Request] { queue.sync { log } }

    /// The paths asked for so far, in order (a path asked for twice is there twice).
    var requestedPaths: [String] { requests.map(\.path) }

    func requestCount(of path: String) -> Int { requests.filter { $0.path == path }.count }

    /// The requests for `path` that are being held back right now.
    func waitingCount(of path: String) -> Int { queue.sync { parked.filter { $0.request.path == path }.count } }

    /// Requests that were answered (a held one only after its release).
    var answeredPaths: [String] { queue.sync { answered.map(\.path) } }

    // MARK: - The wire

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                // (A client that gave up - AVPlayer does when a jump makes a request useless - takes its held request with it.)
                self?.connections[id] = nil
                self?.parked.removeAll { $0.connection === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(header: buffer[buffer.startIndex..<end.lowerBound], on: connection)
            } else if error == nil, !isComplete, buffer.count < 64 * 1024 {
                self.receive(on: connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(header: Data, on connection: NWConnection) {
        let lines = (String(data: header, encoding: .utf8) ?? "").components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let method = String(parts[0]), target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        var range: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "range" { range = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        let request = Request(target: target, path: path, range: range, at: ProcessInfo.processInfo.systemUptime)
        log.append(request)
        let isHead = method == "HEAD"
        guard method == "GET" || isHead else {
            send(status: "405 Method Not Allowed", body: Data(), on: connection)
            return
        }
        if held.contains(path) {
            parked.append(Parked(connection: connection, request: request, isHead: isHead))
        } else {
            respond(to: connection, request: request, isHead: isHead)
        }
    }

    private func respond(to connection: NWConnection, request: Request, isHead: Bool) {
        if let status = failing[request.path] {
            send(status: "\(status) Error", body: Data("error".utf8), on: connection)
            return
        }
        guard let resource = resources[request.path] else {
            send(status: "404 Not Found", body: Data("not found".utf8), on: connection)
            return
        }
        answered.append(request)
        var body = resource.body
        var status = "200 OK"
        var extra = ""
        if let range = request.range, let bytes = Self.byteRange(range, length: body.count) {
            status = "206 Partial Content"
            extra = "Content-Range: bytes \(bytes.lowerBound)-\(bytes.upperBound - 1)/\(body.count)\r\n"
            body = body.subdata(in: bytes)
        }
        send(status: status, headers: "Content-Type: \(resource.contentType)\r\n\(extra)", body: isHead ? Data() : body, contentLength: body.count, on: connection)
    }

    private func send(status: String, headers: String = "", body: Data, contentLength: Int? = nil, on connection: NWConnection) {
        // No caching: a request that a cache answered would not show in the log, and a test that counts requests would be wrong.
        let head = "HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(contentLength ?? body.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// `bytes=a-b`, `bytes=a-` and `bytes=-n`, cut to the length.
    private static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), length > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
        let ends = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard ends.count == 2 else { return nil }
        if ends[0].isEmpty, let suffix = Int(ends[1]), suffix > 0 { return max(0, length - suffix)..<length }
        guard let first = Int(ends[0]), first < length else { return nil }
        let last = Int(ends[1]).map { min($0, length - 1) } ?? length - 1
        return last >= first ? first..<(last + 1) : nil
    }
}
