import XCTest
@testable import Kensho

final class LogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kensho-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileLog(_ configure: (URL) -> FileLog = { FileLog(url: $0) }) -> FileLog {
        configure(directory.appendingPathComponent("diagnostics.log"))
    }

    private func text(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func url(age: Int) -> URL {
        directory.appendingPathComponent(age == 0 ? "diagnostics.log" : "diagnostics.\(age).log")
    }

    /// A session big enough to be worth keeping.
    private func fill(_ log: FileLog, with label: String) {
        for i in 0..<60 { log.write("\(label) line \(i) with some padding text to make it long", tag: "t") }
    }

    // MARK: - Lines

    func testLineCarriesTimeTagAndText() throws {
        let log = fileLog()
        log.write("hello", tag: "fallback-1")
        log.flush()
        let line = text(of: log.url)
        XCTAssertNotNil(line.range(of: #"^\[\d\d:\d\d:\d\d\.\d{3}\] \[fallback-1\] hello\n$"#, options: .regularExpression), line)
    }

    func testLineWithoutTagHasNoEmptyBrackets() {
        let log = fileLog()
        log.write("hello", tag: "")
        log.flush()
        XCTAssertNotNil(text(of: log.url).range(of: #"^\[\d\d:\d\d:\d\d\.\d{3}\] hello\n$"#, options: .regularExpression))
    }

    func testConsoleAndFileShareOneLineFormat() {
        XCTAssertEqual(LogLine.format(time: "12:00:00.000", tag: "ladder", message: "x"), "[12:00:00.000] [ladder] x")
        XCTAssertEqual(LogLine.format(time: "12:00:00.000", tag: "", message: "x"), "[12:00:00.000] x")
    }

    func testTimestampFormatCanBeChosen() {
        let log = fileLog { FileLog(url: $0, timestampFormat: "yyyy-MM-dd HH:mm:ss.SSS") }
        log.write("x", tag: "t")
        log.flush()
        XCTAssertNotNil(text(of: log.url).range(of: #"^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}\] \[t\] x\n$"#, options: .regularExpression))
    }

    // MARK: - Sessions

    func testSessionHeaderNamesTheAttempt() {
        let log = fileLog { FileLog(url: $0, sessionTitle: "PrismCore diagnostic session") }
        log.beginSession(tag: "fallback-2")
        log.flush()
        let content = text(of: log.url)
        XCTAssertTrue(content.hasPrefix("=== PrismCore diagnostic session: fallback-2 — "), content)
        XCTAssertTrue(content.contains("[fallback-2] session begin"))
    }

    func testBeginSessionSaysWhereTheFileIs() {
        let log = fileLog()
        log.beginSession(tag: "initial")
        log.flush()
        XCTAssertTrue(text(of: log.url).contains("[initial] log file: \(log.url.path)"))
    }

    func testBeginSessionKeepsThePreviousSessionInsteadOfDeletingIt() {
        let log = fileLog()
        log.beginSession(tag: "initial")
        fill(log, with: "first")
        log.flush()
        log.beginSession(tag: "initial")
        log.flush()
        XCTAssertFalse(text(of: log.url).contains("first line"), "the new session starts clean")
        XCTAssertTrue(text(of: url(age: 1)).contains("first line 59"), "the old one moved down the line")
        XCTAssertEqual(log.previousSessionURLs, [url(age: 1)])
    }

    func testASessionThatWasOpenedAndClosedAtOnceIsNotKept() {
        let log = fileLog()
        log.beginSession(tag: "initial")
        fill(log, with: "real")
        log.flush()
        log.beginSession(tag: "initial")   // an empty one follows
        log.beginSession(tag: "initial")   // it is not worth a place
        log.flush()
        XCTAssertTrue(text(of: url(age: 1)).contains("real line 59"), "the real session is still the one before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(age: 2).path))
    }

    func testOnlyTheLastThreeSessionsAreKept() {
        let log = fileLog()
        for label in ["a", "b", "c", "d", "e"] {
            log.beginSession(tag: "initial")
            fill(log, with: label)
        }
        log.flush()
        XCTAssertTrue(text(of: url(age: 0)).contains("e line 0"))
        XCTAssertTrue(text(of: url(age: 1)).contains("d line 0"))
        XCTAssertTrue(text(of: url(age: 2)).contains("c line 0"))
        XCTAssertTrue(text(of: url(age: 3)).contains("b line 0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(age: 4).path), "the fourth one back is gone")
        XCTAssertEqual(log.previousSessionURLs, [url(age: 1), url(age: 2), url(age: 3)], "the latest first")
    }

    func testLinesOfAFallbackChainStayInOneSession() {
        let log = fileLog()
        log.beginSession(tag: "initial")
        log.write("first try died", tag: "initial")
        log.write("second try", tag: "fallback-1")
        log.flush()
        let content = text(of: log.url)
        XCTAssertTrue(content.contains("first try died"))
        XCTAssertTrue(content.contains("second try"))
        XCTAssertTrue(log.previousSessionURLs.isEmpty)
    }

    // MARK: - The cap

    func testAFileThatPassesTheMaximumLosesItsOldestLinesNotTheNewest() {
        let log = fileLog { FileLog(url: $0, maximumBytes: 1_000) }
        for i in 0..<100 { log.write("line number \(i)", tag: "t") }
        log.flush()
        let content = text(of: log.url)
        XCTAssertLessThanOrEqual(content.utf8.count, 1_000 + 80, "stays near the maximum")
        XCTAssertTrue(content.contains("line number 99"), "the newest line is there")
        XCTAssertFalse(content.contains("line number 0\n"), "the oldest is gone")
        let lines = content.split(separator: "\n")
        XCTAssertTrue(lines.first?.hasPrefix("[… the oldest lines") ?? false, "and the file says so")
        XCTAssertTrue(lines.dropFirst().first?.hasPrefix("[") ?? false, "the first kept line is a whole line")
    }

    // MARK: - Fan-out and redaction

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

    func testBeginSessionReachesSinksThatKeepSessionsAndIsIgnoredByTheOthers() {
        final class Plain: LogSink, @unchecked Sendable {
            var lines: [String] = []
            func write(_ line: String, tag: String) { lines.append(line) }
        }
        let plain = Plain()
        let file = fileLog()
        KenshoLog(sinks: [plain, file]).beginSession(tag: "initial")
        file.flush()
        XCTAssertTrue(plain.lines.isEmpty, "a sink without sessions has nothing to do")
        XCTAssertTrue(text(of: file.url).hasPrefix("=== diagnostic session: initial"))
    }

    func testRedactionDropsTokenQueryAndCredentials() {
        let url = URL(string: "https://user:secret@media.example:8920/Videos/42/stream?api_key=TOKEN&static=true#frag")!
        let text = LogRedaction.address(url)
        XCTAssertEqual(text, "https://media.example:8920/Videos/42/stream")
        XCTAssertFalse(text.contains("TOKEN"))
        XCTAssertFalse(text.contains("secret"))
    }
}

final class ErrorDescriptionTests: XCTestCase {
    func testNilIsSaidPlainly() {
        XCTAssertEqual(ErrorDescription.describe(nil), "(nil)")
    }

    func testTheChainIsWalkedWithIndentation() {
        let inner = NSError(domain: "CoreMediaErrorDomain", code: -12889, userInfo: [NSLocalizedDescriptionKey: "No response for media file"])
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed",
            NSLocalizedFailureReasonErrorKey: "An unknown error occurred",
            NSUnderlyingErrorKey: inner,
            "custom": "value",
        ])
        let text = ErrorDescription.describe(outer)
        XCTAssertTrue(text.contains("[0] AVFoundationErrorDomain code=-11800"))
        XCTAssertTrue(text.contains("    failureReason: An unknown error occurred"))
        XCTAssertTrue(text.contains("    custom: value"), "every other userInfo key is listed")
        XCTAssertTrue(text.contains("  [1] CoreMediaErrorDomain code=-12889"), "the nested error is indented one level")
        XCTAssertTrue(text.contains("known meaning: AVPlayer media watchdog"), "a known code says what it is")
    }

    func testAnExternalPlaybackRefusalIsNamed() {
        let text = ErrorDescription.describe(NSError(domain: "AVFoundationErrorDomain", code: -11870))
        XCTAssertTrue(text.contains("externalPlaybackNotSupportedForAsset"))
        XCTAssertTrue(text.contains("says nothing about the network link"))
    }

    func testAnUnknownCodeHasNoMeaningLine() {
        XCTAssertFalse(ErrorDescription.describe(NSError(domain: "X", code: 1)).contains("known meaning"))
    }

    func testAnEndlessChainIsCutOff() {
        var error = NSError(domain: "E", code: 0)
        for code in 1...20 { error = NSError(domain: "E", code: code, userInfo: [NSUnderlyingErrorKey: error]) }
        let lines = ErrorDescription.describe(error).split(separator: "\n").filter { $0.contains("code=") }
        XCTAssertEqual(lines.count, 6)
    }
}
