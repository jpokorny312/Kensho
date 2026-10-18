import Foundation

/// Identifies one engine session. Every load, prepared replacement and stop
/// starts a new one; anything an engine reports for an epoch that is not (or
/// no longer) current is dropped. Without this, a late "ready" from the item
/// that was just replaced flips the UI to playing over a black frame.
public struct Epoch: Hashable, Comparable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static let initial = Epoch(0)
    func next() -> Epoch { Epoch(rawValue + 1) }
    public static func < (lhs: Epoch, rhs: Epoch) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifies one seek. A newer seek supersedes an older one, and only the
/// completion of the current one may resume playback.
public struct SeekToken: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    func next() -> SeekToken { SeekToken(rawValue + 1) }
}

public enum VideoRange: String, Sendable {
    case sdr, hdr10, hlg, dolbyVision
}

/// What the viewer has chosen. `nil` means "off" for subtitles and "engine
/// default" for audio.
public struct TrackSelection: Equatable, Sendable {
    public var audio: Int?
    public var subtitle: Int?
    public init(audio: Int? = nil, subtitle: Int? = nil) {
        self.audio = audio
        self.subtitle = subtitle
    }
}

public struct QualityChoice: Equatable, Sendable {
    public var id: String
    public var range: VideoRange
    public init(id: String, range: VideoRange) {
        self.id = id
        self.range = range
    }
}

public struct MediaSource: Equatable, Sendable {
    public var id: String
    public var range: VideoRange
    public init(id: String, range: VideoRange) {
        self.id = id
        self.range = range
    }
}

public enum Phase: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    /// Starved of data while the viewer wants to play.
    case buffering
    case seeking
    /// A replacement session has taken over and is getting to the position
    /// (or the running one died and its replacement is the way on).
    case switching
    case failed(String)
    case stopped
}

/// A replacement session (a quality change) that is being prepared WHILE the
/// running one keeps playing: the viewer sees no gap, only the moment it takes
/// over. (The players make it before they break it; the position is read when
/// the replacement takes over, not when it was asked for.)
public struct PendingSwap: Equatable, Sendable {
    public var epoch: Epoch
    public var quality: QualityChoice
    /// The replacement is prepared and waits only for a steady moment to take over (not in the middle of a seek).
    var isReady: Bool
}

public struct PlaybackState: Equatable, Sendable {
    /// The session that is live: engine reports for any other epoch are dropped.
    public var epoch: Epoch = .initial
    public var phase: Phase = .idle
    /// What the viewer wants, kept apart from what the engine is doing. A seek
    /// or a swap interrupts playback, but must not forget that the viewer had
    /// pressed play - or silently resume a viewer who had paused.
    public var wantsPlay: Bool = false
    public var source: MediaSource?
    public var quality: QualityChoice?
    public var selection: TrackSelection = TrackSelection()
    /// Position the UI shows. During a seek this is the target, not whatever
    /// the engine still reports from before the jump.
    public var position: TimeInterval = 0
    /// A replacement being prepared; the running session is `epoch` until it takes over.
    public internal(set) var swap: PendingSwap?

    var seekToken: SeekToken = SeekToken(0)
    var pendingSeek: TimeInterval?
    var pendingSelection: TrackSelection?
    var lastQualityChange: TimeInterval?
    /// The last epoch handed out. `epoch` is the live one, which is not always
    /// the latest: a replacement being prepared already has its own.
    var lastIssuedEpoch: Epoch = .initial
    /// Why the running session died while a replacement was on its way (the replacement is then the way on; if it fails too, this is the failure).
    var lostWhileSwapping: String?

    public init() {}

    /// True when nothing is mid-flight and a track or quality change may be
    /// applied immediately.
    public var isSteady: Bool {
        switch phase {
        case .playing, .paused, .buffering: return true
        default: return false
        }
    }
}
