import XCTest
@testable import Kensho

final class LogTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kensho-test-\(UUID().uuidString).log")
    }

    func testLineCarriesTagAndText() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = FileLog(url: url)
        log.write("hello", tag: "fallback-1")
        log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[fallback-1] hello\n"))
    }

    func testFileRotatesPastMaximumSize() throws {
        let url = tempURL()
        let older = url.deletingPathExtension().appendingPathExtension("1.log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: older)
        }
        let log = FileLog(url: url, maximumBytes: 200)
        for i in 0..<20 { log.write("line number \(i) with some padding text", tag: "t") }
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: older.path))
        let newest = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(newest.contains("line number 19"))
    }

    func testBeginSessionStartsFreshFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = FileLog(url: url)
        log.write("old attempt", tag: "initial")
        log.flush()
        log.beginSession(tag: "initial")
        log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("old attempt"))
        XCTAssertTrue(text.contains("log file:"))
    }

    func testKenshoLogFansOutToEverySink() {
        final class Recorder: LogSink, @unchecked Sendable {
            var lines: [String] = []
            func write(_ line: String, tag: String) { lines.append("\(tag):\(line)") }
        }
        let a = Recorder(), b = Recorder()
        KenshoLog(sinks: [a, b]).log("x", tag: "t")
        XCTAssertEqual(a.lines, ["t:x"])
        XCTAssertEqual(b.lines, ["t:x"])
    }

    func testRedactionDropsTokenQueryAndCredentials() {
        let url = URL(string: "https://user:secret@media.example:8920/Videos/42/stream?api_key=TOKEN&static=true#frag")!
        let text = LogRedaction.address(url)
        XCTAssertEqual(text, "https://media.example:8920/Videos/42/stream")
        XCTAssertFalse(text.contains("TOKEN"))
        XCTAssertFalse(text.contains("secret"))
    }
}
