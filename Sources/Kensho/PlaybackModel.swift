import Foundation

/// Identifies one engine session. Every load, quality swap and stop starts a
/// new one; anything an engine reports for an older epoch is dropped. Without
/// this, a late "ready" from the item that was just replaced flips the UI to
/// playing over a black frame.
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
    /// A replacement engine session (quality change) is being prepared.
    case switching
    case failed(String)
    case stopped
}

public struct PlaybackState: Equatable, Sendable {
    public var epoch: Epoch = .initial
    public var phase: Phase = .idle
    /// What the viewer wants, kept apart from what the engine is doing. A seek
    /// or a swap interrupts playback, but must not forget that the viewer had
    /// pressed play — or silently resume a viewer who had paused.
    public var wantsPlay: Bool = false
    public var source: MediaSource?
    public var quality: QualityChoice?
    public var selection: TrackSelection = TrackSelection()
    /// Position the UI shows. During a seek this is the target, not whatever
    /// the engine still reports from before the jump.
    public var position: TimeInterval = 0

    var seekToken: SeekToken = SeekToken(0)
    var pendingSeek: TimeInterval?
    var pendingSelection: TrackSelection?
    var lastQualityChange: TimeInterval?

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
