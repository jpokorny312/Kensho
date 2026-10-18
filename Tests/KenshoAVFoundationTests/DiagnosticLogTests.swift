import XCTest
import Kensho
@testable import KenshoAVFoundation

/// The app's log is one per process and lives in a place that depends on the platform; these only look, they write nothing (a test must not
/// add lines to the diagnostics file of whoever runs it).
final class DiagnosticLogTests: XCTestCase {
    func testTheFileHasTheNameTheScriptsAndTheSettingsLookFor() {
        XCTAssertEqual(DiagnosticLog.fileName, "prismcore-diagnostics.log")
        XCTAssertEqual(DiagnosticLog.file.url.lastPathComponent, "prismcore-diagnostics.log")
        XCTAssertEqual(DiagnosticLog.logFilePath, DiagnosticLog.file.url.path)
    }

    func testItLivesInDocumentsOnThePhoneAndInCachesOnTheTV() {
        #if os(tvOS)
        XCTAssertEqual(DiagnosticLog.directory, FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
        #else
        XCTAssertEqual(DiagnosticLog.directory, FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        #endif
        XCTAssertEqual(DiagnosticLog.file.url.deletingLastPathComponent(), DiagnosticLog.directory)
    }

    func testItWritesToTheConsoleAndTheFile() {
        XCTAssertEqual(DiagnosticLog.kensho.sinks.count, 2)
        XCTAssertTrue(DiagnosticLog.kensho.sinks.contains { $0 is ConsoleLog })
        XCTAssertTrue(DiagnosticLog.kensho.sinks.contains { $0 is FileLog })
    }

    func testAnErrorIsDescribedTheWayTheOldLogDid() {
        let text = DiagnosticLog.describe(error: NSError(domain: "AVFoundationErrorDomain", code: -11829))
        XCTAssertTrue(text.contains("[0] AVFoundationErrorDomain code=-11829"))
        XCTAssertTrue(text.contains("fileFailedToParse"))
        XCTAssertEqual(DiagnosticLog.describe(error: nil), "(nil)")
    }
}
