import Foundation

/// An error written out in full, for a log that is read a week later. Every word of it that the error brought along goes through
/// `LogRedaction.text`: an address that failed carries the access token of the stream.
public enum ErrorDescription {
    /// Full recursive error chain - domain, code, localized description,
    /// failure reason, recovery suggestion, and every remaining userInfo
    /// key - for `error` and every `NSUnderlyingError` nested inside it.
    /// `String(describing:)` on an NSError already shows nested errors, but
    /// silently drops any recovery suggestion and every userInfo key beyond
    /// the description - exactly the fields most likely to actually name
    /// what -16170/-11829 mean, if AVFoundation sets them at all.
    public static func describe(_ error: NSError?) -> String {
        guard let error else { return "(nil)" }
        var lines: [String] = []
        var current: NSError? = error
        var depth = 0
        while let err = current, depth < 6 {
            let indent = String(repeating: "  ", count: depth)
            lines.append("\(indent)[\(depth)] \(err.domain) code=\(err.code)")
            if let known = knownMeaning(domain: err.domain, code: err.code) {
                lines.append("\(indent)    known meaning: \(known)")
            }
            if !err.localizedDescription.isEmpty {
                lines.append("\(indent)    description: \(LogRedaction.text(err.localizedDescription))")
            }
            if let reason = err.localizedFailureReason {
                lines.append("\(indent)    failureReason: \(LogRedaction.text(reason))")
            }
            if let suggestion = err.localizedRecoverySuggestion {
                lines.append("\(indent)    recoverySuggestion: \(LogRedaction.text(suggestion))")
            }
            let skip: Set<String> = [NSUnderlyingErrorKey, NSLocalizedDescriptionKey, NSLocalizedFailureReasonErrorKey, NSLocalizedRecoverySuggestionErrorKey]
            for key in err.userInfo.keys.sorted() where !skip.contains(key) {
                lines.append("\(indent)    \(key): \(LogRedaction.text(String(describing: err.userInfo[key]!)))")
            }
            current = err.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return lines.joined(separator: "\n")
    }

    /// What this codebase has actually established about the error codes
    /// this specific investigation keeps hitting - researched once
    /// (Apple's own SDK headers, PrismCore's source, and public forum
    /// threads) rather than left as bare numbers with nothing to search
    /// for. None of these are in Apple's own public documentation beyond
    /// what's noted below; if you learn more, extend this table rather than
    /// letting a future reader re-run the same research from scratch.
    ///
    /// - `AVFoundationErrorDomain -11829`: publicly named -
    ///   `AVError.Code.fileFailedToParse`, declared in the public SDK header
    ///   `AVError.h`. Apple's one-line documentation: "the file is corrupt
    ///   or in an unrecognized format." The "Cannot Open" text seen at
    ///   runtime is a localized description AVFoundation attaches at the
    ///   call site, not part of the header.
    /// - `AVFoundationErrorDomain -11870`: publicly named -
    ///   `AVError.Code.externalPlaybackNotSupportedForAsset`, `AVError.h`:
    ///   the system tried to play the asset on an external route (AirPlay, a
    ///   CarPlay screen) and the receiver cannot be given it. Found 2026-10-18
    ///   in the log of a phone connected to the CarPlay simulator: EVERY item
    ///   of the app failed this way after ~10 s, and the player took it for a
    ///   weak link and stepped the quality down. It says nothing about the link.
    /// - `AVFoundationErrorDomain -11868` / `-11848`, `NSURLErrorDomain
    ///   -1002`: PrismCore's own known "master rejected" set - see
    ///   `MasterRejection.errorCodes` in its source
    ///   (Sources/PrismCore/HLS/MasterRejection.swift). Note `-11848` is a
    ///   one-digit-off false friend of `-12848` below - different error,
    ///   different domain role, easy to misread as the same thing.
    /// - `CoreMediaErrorDomain -12889`: an AVPlayer-internal "media
    ///   watchdog" timeout - "No response for media file" after some
    ///   interval waiting for response headers. PrismCore's own docs say
    ///   ~3.5s; independent Apple Developer Forum reports say 4.096s in one
    ///   case and 10s in another - the exact window isn't a fixed public
    ///   constant, or varies by iOS version/context.
    /// - `CoreMediaErrorDomain -16170`: genuinely undocumented anywhere
    ///   reachable - absent from every Apple SDK header (public and the
    ///   `.tbd` symbol stubs), absent from PrismCore's source, and on the
    ///   public web limited to one unanswered Apple Developer Forum thread
    ///   (760617) about 4K HEVC on Apple TV 4K with no explanation given.
    /// - `CoreMediaErrorDomain -12848`: same story - undocumented in every
    ///   SDK header and in PrismCore, and on the web limited to one Apple
    ///   Developer Forum bug report (thread 800805) about ffmpeg-remuxed
    ///   fMP4/HLS failing only on iOS, where Apple's own engineer asked for
    ///   a Feedback Assistant case rather than explaining the code.
    /// - Both `-16170` and `-12848` most likely belong to CoreMedia's
    ///   private internal error family (codenamed "Fig" - confirmed via
    ///   `CoreMedia.tbd`'s exported symbols, e.g. `kFigPlayerError_*`,
    ///   `kFigBaseObjectError_*`, `FigWatchdog*`, all in the same
    ///   -128xx/-129xx/-161xx neighborhood), which has no public listing.
    public static func knownMeaning(domain: String, code: Int) -> String? {
        switch (domain, code) {
        case ("AVFoundationErrorDomain", -11829):
            return "AVError.Code.fileFailedToParse (publicly documented) — \"the file is corrupt or in an unrecognized format\""
        case ("AVFoundationErrorDomain", -11870):
            return "AVError.Code.externalPlaybackNotSupportedForAsset (publicly documented) — the system tried external playback (AirPlay / a CarPlay screen) and the receiver cannot take this asset; says nothing about the network link"
        case ("AVFoundationErrorDomain", -11868), ("AVFoundationErrorDomain", -11848), ("NSURLErrorDomain", -1002):
            return "in PrismCore's own MasterRejection.errorCodes set — a known \"master playlist rejected\" signal"
        case ("CoreMediaErrorDomain", -12889):
            return "AVPlayer media watchdog: \"no response for media file\" — timed out waiting for response headers (window varies by source: ~3.5s per PrismCore, 4.1-10s per Apple forum reports)"
        case ("CoreMediaErrorDomain", -16170):
            return "UNDOCUMENTED — not in any Apple SDK header, not in PrismCore, not meaningfully explained anywhere public (one unanswered Apple dev forum thread only). Likely private CoreMedia \"Fig\" family, no public mapping exists."
        case ("CoreMediaErrorDomain", -12848):
            return "UNDOCUMENTED — not in any Apple SDK header, not in PrismCore, not meaningfully explained anywhere public (one Apple dev forum bug report, unanswered beyond \"file a Feedback Assistant case\"). Likely private CoreMedia \"Fig\" family, no public mapping exists."
        case ("CoreMediaErrorDomain", -19602):
            return "UNDOCUMENTED — first seen 2026-09-24, firing ~0.6s after a successful PrismCore re-anchor (AVPlayerItem.status went .failed right after `post-reanchor segment produced`, no PrismCore-side error logged). Not in MasterRejection.errorCodes; `.playerItemFailedToLoad` routes ANY `.failed` through attemptMasterRejectionFallback regardless of code, which is why this triggered a full fallback-tier rebuild (slow) rather than the cheaper reconnect path. Recurred 2026-10-07 on a real iPhone, as AVPlayerItemFailedToPlayToEndTime this time: 1080p h264 MKV (HE-AAC + E-AC-3 5.1), resumed at 714s, so the stream began at the keyframe before (710.40s); `.readyToPlay` with the first 2.8 MB fetched, 0.05s of playback (currentTime 710.40 → 710.45), then -19602. The reconnect (new session, again from the keyframe before the position, 708.9s) played on without trouble, ~4s later — transient, but the PrismCore log of that session was gone by the time anybody looked (the next episode's session overwrote it; the last three sessions are kept now: prismcore-diagnostics.1.log …). Both sightings: a session that begins at a re-anchored offset, failing in the first second of playback. Extend this note, and read the .N.log of the failing session first, if it recurs."
        default:
            return nil
        }
    }
}
