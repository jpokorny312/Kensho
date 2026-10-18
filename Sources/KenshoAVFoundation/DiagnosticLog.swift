import Foundation
import AVFoundation
import Kensho

/// The app's diagnostics log — one per process, the same on the iPhone and the Apple TV: every PrismCore session, every fallback tier, every
/// reconnect and swap writes here, to Xcode's console and to a file that can be read afterwards with no cable attached.
///
/// The bugs this exists to chase (CoreMediaErrorDomain -16170 et al.) only reproduce with real Dolby Vision / Atmos content, which only exists on real
/// hardware, where keeping a live Xcode console attached through an entire fallback chain isn't always practical.
///
/// One playback attempt (a fresh item, a new episode) starts a clean file (`beginSession`) and the file of the attempt before moves one place down
/// the line of kept sessions — `prismcore-diagnostics.1.log` … `.3.log` — instead of being overwritten: the start of the next episode, a minute after a
/// failure, used to wipe the only record of it. Fallback tiers and reconnects of the SAME attempt only append, under their own tag, so a whole fallback
/// chain for one movie lands in one file.
public enum DiagnosticLog {
    public static let fileName = "prismcore-diagnostics.log"

    /// Where the file lives. iPhone and iPad: Documents — Settings → Share Diagnostic Log reads it, `devicectl device copy from --domain-type
    /// appDataContainer` finds it, and the Files app does not show it (that would show every download as well, past the parental control). Apple
    /// TV: Caches — a tvOS app has no Documents folder that is kept (`devicectl … --source Library/Caches/prismcore-diagnostics.log`).
    public static var directory: URL {
        #if os(tvOS)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    public static let file = FileLog(url: directory.appendingPathComponent(fileName), sessionTitle: "PrismCore diagnostic session")

    /// The log as the shared code writes to it: the console and the file.
    public static let kensho = KenshoLog(sinks: [ConsoleLog(), file])

    public static func beginSession(tag: String) {
        file.beginSession(tag: tag)
    }

    /// The files of the sessions before the current one, the latest first (only those that exist).
    public static var previousSessionURLs: [URL] { file.previousSessionURLs }

    public static func log(_ message: String, tag: String = "") {
        kensho.log(message, tag: tag)
    }

    /// Full recursive error chain — domain, code, localized description, failure reason, recovery suggestion and every other userInfo key — for
    /// `error` and everything nested inside it, with what is known about the codes this investigation keeps meeting.
    public static func describe(error: NSError?) -> String {
        ErrorDescription.describe(error)
    }

    /// AVPlayerItem's own network-transport diagnostics (`errorLog()`, `accessLog()`): AVFoundation's own record of what it requested and what came
    /// back, a different vantage point than a side URLSession probe racing the same server can offer.
    public static func dumpPlayerItemLogs(for item: AVPlayerItem, tag: String) {
        PlayerItemLogDump.dump(item, log: kensho, tag: tag)
    }

    public static var logFilePath: String { file.url.path }
}
