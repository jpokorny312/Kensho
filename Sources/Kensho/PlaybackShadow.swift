import Foundation

/// The state machine, run next to the player code the app has today. It is told what that code does (what the viewer asked for, what its policies
/// decided) and what the player reports, it decides what it would have done, and it writes down both - and where the two disagree. It controls
/// nothing: its engine does nothing at all.
///
/// Why: the app's player keeps its state in a dozen places (`isPlaying`, `isBuffering`, a connection state, flags for a swap that is under way, the
/// position of a jump that was not sent yet, ...), and the places lose each other: a viewer who pauses while the stream is swapped is playing again
/// when the new item starts. The log of a real run says where that happens, before anything is moved over to the reducer - and what it cannot say is
/// what the reducer lacks, which shows as the same disagreement on a path the app handles without trouble.
///
/// Every line carries the tag `kensho`. A disagreement that lasts is a line with `DEVIATION` in it, which a test can look for.
@MainActor
public final class PlaybackShadow {
    /// What the app's own player code says about itself, once in a while (every tick of its time observer): the other side of the comparison.
    public struct Observation: Equatable, Sendable {
        /// The app's own flag: the viewer wants playback (`isPlaying`).
        public var wantsToPlay: Bool
        /// The player is waiting for data (`timeControlStatus == .waitingToPlayAtSpecifiedRate`).
        public var isWaitingForData: Bool
        /// The app has given the stream up and is getting another (`ConnectionState.reconnecting`).
        public var isReconnecting: Bool
        /// The app has given up altogether (`ConnectionState.failed`).
        public var hasFailed: Bool
        /// A step down or up is being made (`isDowngrading || isUpgrading`).
        public var isChangingQuality: Bool
        /// A jump was asked for and has not been sent to the player yet (the taps of the skip buttons are gathered for a moment).
        public var hasUnsentJump: Bool
        /// Where the player is, in seconds.
        public var position: TimeInterval
        /// The item that plays.
        public var itemId: String

        public init(
            wantsToPlay: Bool, isWaitingForData: Bool, isReconnecting: Bool, hasFailed: Bool,
            isChangingQuality: Bool, hasUnsentJump: Bool, position: TimeInterval, itemId: String
        ) {
            self.wantsToPlay = wantsToPlay
            self.isWaitingForData = isWaitingForData
            self.isReconnecting = isReconnecting
            self.hasFailed = hasFailed
            self.isChangingQuality = isChangingQuality
            self.hasUnsentJump = hasUnsentJump
            self.position = position
            self.itemId = itemId
        }
    }

    /// The engine of a shadow: it writes down what it is asked and does nothing.
    private final class NullEngine: PlaybackEngine {
        var onEvent: ((PlaybackEvent) -> Void)?
        private(set) var performed: [PlaybackEffect] = []
        func perform(_ effect: PlaybackEffect) { performed.append(effect) }
    }

    /// How long a disagreement has to last before it is one. The two sides report to each other through events that take a moment (a jump is
    /// a second of seeking, a swap takes the time it takes), and a line for each of those would bury the ones that matter.
    struct Thresholds {
        var wantsPlay: TimeInterval = 1.5
        var phase: TimeInterval = 5
        var position: TimeInterval = 4
        var item: TimeInterval = 2
    }

    private let log: KenshoLog
    private let tag: String
    private let clock: () -> TimeInterval
    private let engine = NullEngine()
    private let thresholds: Thresholds
    private(set) var coordinator: PlaybackCoordinator!

    private var lastState = PlaybackState()
    private var phaseSince: TimeInterval = 0
    private var lastHeartbeat: TimeInterval = -.infinity
    private var isEnded = false

    /// Disagreements that are going on: since when, and whether they have been written down (they are once they have lasted long enough).
    private struct OpenDeviation {
        var since: TimeInterval
        var detail: String
        var reported = false
    }
    private var open: [String: OpenDeviation] = [:]

    /// What has happened, for the summary and for tests.
    public private(set) var eventCount = 0
    public private(set) var ignoredCount = 0
    public private(set) var deviationCount = 0

    public var state: PlaybackState { coordinator.state }
    /// The instructions the state machine has given, in order (nobody carries them out).
    public var instructions: [PlaybackEffect] { engine.performed }

    public init(log: KenshoLog, tag: String = "kensho", clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.log = log
        self.tag = tag
        self.clock = clock
        self.thresholds = Thresholds()
        install()
    }

    init(log: KenshoLog, tag: String = "kensho", clock: @escaping () -> TimeInterval, thresholds: Thresholds) {
        self.log = log
        self.tag = tag
        self.clock = clock
        self.thresholds = thresholds
        install()
    }

    private func install() {
        coordinator = PlaybackCoordinator(engine: engine, clock: clock)
        coordinator.onTransition = { [unowned self] event, state, effects in self.record(event, state, effects) }
    }

    // MARK: - What the viewer and the app's policies do

    /// A session begins: the first item of a player, a new episode, or a stream that is made again from scratch (a reconnect, a fallback, a track
    /// switch that rebuilds the stream). `reason` is the name the app gives the attempt.
    ///
    /// - Parameter startsPlayback: the viewer starts something (the player opens, a new episode): playback is wanted from here. False for a
    ///   stream the app's policies replace under the viewer's feet: what the viewer wanted stays what it was. (A `load` always wants
    ///   playback, as the viewer starting something does; a `reload` leaves it as it was.) The app's own `replaceItem` sets
    ///   `isPlaying = true` for every item it puts in; where the viewer had paused, the comparison then says so.
    public func begin(item: String, startAt: TimeInterval, quality: String?, audio: Int?, subtitle: Int?, reason: String, startsPlayback: Bool = true) {
        guard !isEnded else { return }
        let before = coordinator.state
        let isReload = !startsPlayback && before.source != nil && before.phase != .idle && before.phase != .stopped
        log.log("begin (\(reason)): \(item) at \(Self.seconds(startAt))" + (isReload && !before.wantsPlay ? ", the viewer had paused: that stays" : ""), tag: tag)
        let selection = TrackSelection(audio: audio, subtitle: subtitle)
        let choice = quality.map { QualityChoice(id: $0, range: .sdr) }
        if isReload && before.source?.id == item {
            coordinator.send(.reload(startAt: startAt, selection: selection, quality: choice))
        } else {
            coordinator.load(MediaSource(id: item, range: .sdr), startAt: startAt, selection: selection, quality: choice)
        }
    }

    /// The player is closed.
    public func end() {
        guard !isEnded else { return }
        coordinator.stop()
        isEnded = true
        for key in open.keys.sorted() where open[key]?.reported == true {
            log.log("DEVIATION \(key) was still going on when the player closed: \(open[key]?.detail ?? "")", tag: tag)
        }
        log.log("end: \(eventCount) events, \(ignoredCount) of them without effect, \(deviationCount) deviations", tag: tag)
    }

    public func play() { guard !isEnded else { return }; coordinator.play() }
    public func pause() { guard !isEnded else { return }; coordinator.pause() }
    public func seek(to position: TimeInterval) { guard !isEnded else { return }; coordinator.seek(to: position) }
    public func selectAudio(_ stream: Int?) { guard !isEnded else { return }; coordinator.selectAudio(stream) }
    public func selectSubtitle(_ stream: Int?) { guard !isEnded else { return }; coordinator.selectSubtitle(stream) }

    /// The app decides to change the quality of the stream and begins to get the other one ready (the old one plays on meanwhile).
    public func qualityChangeBegins(to quality: String, reason: String) {
        guard !isEnded else { return }
        log.log("quality change to \(quality) (\(reason))", tag: tag)
        let before = coordinator.state.swap
        coordinator.requestQuality(QualityChoice(id: quality, range: .sdr))
        if coordinator.state.swap == before {
            log.log("the state machine would not have started it: \(refusal(for: quality))", tag: tag)
        }
    }

    /// The app has the other stream ready and swaps it in now (it has made its last checks).
    public func qualityChangeReady() {
        guard !isEnded else { return }
        guard let swap = coordinator.state.swap else {
            log.log("the other stream is swapped in, but the state machine has no change under way: it follows the swap as a new session", tag: tag)
            followAsNewSession()
            return
        }
        coordinator.send(.swapPrepared(swap.epoch))
    }

    /// The app has put a new item in and says whether it plays on - its `replaceItem` always does. Where the viewer had paused, that is the loss this
    /// state machine exists to prevent (a reconnect, a rebuild or a swap undoes his pause), and it is said at once: the comparison that runs with the
    /// ticks only reports what lasts, and the app sets the flag back some moments later.
    public func replacementPlays(_ appPlays: Bool) {
        guard !isEnded, appPlays, !coordinator.state.wantsPlay else { return }
        deviationCount += 1
        log.log("DEVIATION replacement-resumes: the app plays on after replacing the stream, the viewer had paused (the state machine keeps his pause, \(Self.phase(coordinator.state.phase)))", tag: tag)
    }

    /// The app calls the change off after it began it (the old stream recovered, the player was changed meanwhile, resolving failed).
    public func qualityChangeCalledOff(_ why: String) {
        guard !isEnded else { return }
        guard let swap = coordinator.state.swap else { return }
        log.log("quality change called off: \(why)", tag: tag)
        coordinator.send(.swapFailed(swap.epoch, reason: why))
    }

    /// The name a stream of a bitrate cap goes by in the state machine and in the log: "original" for none.
    public static func qualityName(capMbps: Double?) -> String {
        capMbps.map { String(format: "%gMbps", $0) } ?? "original"
    }

    // MARK: - What the player says

    public func playerIsReady() {
        guard !isEnded else { return }
        let s = coordinator.state
        coordinator.send(s.phase == .switching ? .swapFinished(s.epoch) : .engineReady(s.epoch))
    }

    public func playerFailed(_ reason: String) {
        guard !isEnded else { return }
        // (The app tells of a failure from several places - the notification, the start of the reconnect - for one and the same.)
        if case .failed = coordinator.state.phase { return }
        coordinator.send(.engineFailed(coordinator.state.epoch, reason: reason))
    }

    /// The player failed with this error: the domain and the code say it in a line (the whole chain is in the app's log at that point).
    public func playerFailed(error: NSError?) {
        playerFailed(error.map { "\($0.domain) \($0.code)" } ?? "unknown error")
    }

    public func playerStalled() { guard !isEnded else { return }; coordinator.send(.engineStalled(coordinator.state.epoch)) }
    public func playerRecovered() { guard !isEnded else { return }; coordinator.send(.engineRecovered(coordinator.state.epoch)) }

    public func playerMoved(to position: TimeInterval) {
        guard !isEnded else { return }
        coordinator.send(.engineTick(coordinator.state.epoch, position: position))
    }

    /// A jump the app sent has landed.
    public func jumpLanded() {
        guard !isEnded else { return }
        let s = coordinator.state
        coordinator.send(.seekFinished(s.epoch, s.seekToken))
    }

    /// The item played to its end. (The state machine has no event for it yet; the line says what it thinks of the player then.)
    public func playerReachedTheEnd() {
        guard !isEnded else { return }
        log.log("the item played to its end; the state machine is in \(Self.phase(coordinator.state.phase)) and has no event for that", tag: tag)
    }

    // MARK: - The comparison

    /// Compares the state machine with the app; call it with every tick of the app's time observer. A disagreement is written down when it has lasted
    /// longer than a moment, and once more when it is over.
    public func compare(with app: Observation) {
        guard !isEnded else { return }
        let now = clock()
        let s = coordinator.state
        var found: [String: String] = [:]

        if app.wantsToPlay != s.wantsPlay {
            found["wants-play"] = "the app wants to play: \(app.wantsToPlay); the state machine: \(s.wantsPlay) (it is \(Self.phase(s.phase)))"
        }
        if let source = s.source, source.id != app.itemId {
            found["item"] = "the app plays \(app.itemId); the state machine \(source.id)"
        }
        // (A disagreement about what the viewer wants shows in the phase as well; it is one cause and gets one line.)
        var judged = app
        if found["wants-play"] != nil { judged.wantsToPlay = s.wantsPlay }
        if !Self.expectedPhases(for: judged).contains(Self.kind(of: s.phase)) {
            found["phase"] = "the app: \(Self.describe(app)); the state machine is \(Self.phase(s.phase))"
                + (s.swap != nil ? " with a replacement on its way" : "")
        } else if Self.transitional.contains(Self.kind(of: s.phase)), !Self.isExcusedFromBeingTransitional(app), now - phaseSince >= thresholds.phase {
            // The app has long been playing without a wait, and the state machine is still getting somewhere: an answer never reached it.
            found["phase-stuck"] = "the app: \(Self.describe(app)); the state machine has been \(Self.phase(s.phase)) for \(Self.seconds(now - phaseSince))"
        }
        if s.swap != nil, !app.isChangingQuality {
            found["swap"] = "the state machine has a replacement on its way (\(s.swap?.quality.id ?? "?")), the app is not changing the quality"
        }
        if s.isSteady, abs(app.position - s.position) > 5 {
            found["position"] = "the player is at \(Self.seconds(app.position)); the state machine at \(Self.seconds(s.position))"
        }

        for (key, detail) in found {
            if open[key] == nil { open[key] = OpenDeviation(since: now, detail: detail) } else { open[key]?.detail = detail }
        }
        for key in open.keys.sorted() {
            guard let deviation = open[key] else { continue }
            if found[key] == nil {
                if deviation.reported {
                    log.log("DEVIATION \(key) is over after \(Self.seconds(now - deviation.since))", tag: tag)
                }
                open[key] = nil
            } else if !deviation.reported, now - deviation.since >= threshold(for: key) {
                open[key]?.reported = true
                deviationCount += 1
                log.log("DEVIATION \(key): \(deviation.detail) — for \(Self.seconds(now - deviation.since)) now", tag: tag)
                if key == "swap", let swap = coordinator.state.swap {
                    // (Left alone it would keep every later change of quality from beginning.)
                    coordinator.send(.swapFailed(swap.epoch, reason: "the app has no change under way"))
                }
            }
        }
    }

    private func threshold(for key: String) -> TimeInterval {
        switch key {
        case "wants-play": return thresholds.wantsPlay
        case "position": return thresholds.position
        case "item", "swap": return thresholds.item
        default: return 0   // (the dwell is in the condition)
        }
    }

    /// The phases that are on the way to another one: the state machine waits for an answer in them.
    static let transitional: Set<PhaseKind> = [.loading, .seeking, .switching]

    /// What makes a long stay in a transitional phase normal: the app is itself waiting, reconnecting, changing the quality or holding a jump.
    static func isExcusedFromBeingTransitional(_ app: Observation) -> Bool {
        app.isWaitingForData || app.isReconnecting || app.hasFailed || app.isChangingQuality || app.hasUnsentJump
    }

    /// A phase without what some of them carry (the reason of a failure).
    enum PhaseKind: Hashable {
        case idle, loading, playing, paused, buffering, seeking, switching, failed, stopped
    }

    static func kind(of phase: Phase) -> PhaseKind {
        switch phase {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .buffering: return .buffering
        case .seeking: return .seeking
        case .switching: return .switching
        case .failed: return .failed
        case .stopped: return .stopped
        }
    }

    /// The phases the state machine may be in, given what the app says. Wide where the two sides take a while to meet (a jump, a swap, a
    /// reconnect), narrow where they must agree.
    static func expectedPhases(for app: Observation) -> Set<PhaseKind> {
        if app.hasFailed { return [.failed] }
        if app.isReconnecting { return [.failed, .loading, .switching] }
        if app.isChangingQuality { return [.playing, .paused, .buffering, .seeking, .switching, .loading] }
        if app.hasUnsentJump { return [.playing, .paused, .buffering, .seeking] }
        if !app.wantsToPlay { return [.paused, .seeking, .loading, .switching] }
        // The wait for data after play() or a jump is no stall for the state machine, a real one is: while the app waits, any of these.
        if app.isWaitingForData { return [.playing, .buffering, .seeking, .loading, .switching] }
        return [.playing, .seeking, .loading, .switching]
    }

    // MARK: - The log

    private func record(_ event: PlaybackEvent, _ state: PlaybackState, _ effects: [PlaybackEffect]) {
        let before = lastState
        lastState = state
        if Self.kind(of: before.phase) != Self.kind(of: state.phase) { phaseSince = clock() }
        eventCount += 1
        let isTick: Bool
        if case .engineTick = event { isTick = true } else { isTick = false }
        let changed = state != before
        if !changed && effects.isEmpty { ignoredCount += 1 }
        if isTick {
            // Ticks are twice a second: a line when the phase changes (never, for a tick) and a heartbeat every ten seconds.
            let now = clock()
            if now - lastHeartbeat >= 10 {
                lastHeartbeat = now
                log.log("\(Self.phase(state.phase)) at \(Self.seconds(state.position)) (epoch \(state.epoch.rawValue)\(state.wantsPlay ? "" : ", paused by the viewer"))", tag: tag)
            }
            return
        }
        var line = Self.describe(event)
        if !changed && effects.isEmpty {
            line += " — no effect (\(Self.phase(state.phase)), epoch \(state.epoch.rawValue))"
        } else {
            line += " → \(Self.phase(state.phase)) epoch \(state.epoch.rawValue)"
            if before.phase == state.phase { line += " (unchanged)" } else { line += " (was \(Self.phase(before.phase)))" }
            if let swap = state.swap { line += ", replacement #\(swap.epoch.rawValue) \(swap.quality.id) on its way" }
            if !effects.isEmpty { line += ", instructs: " + effects.map(Self.describe).joined(separator: ", ") }
        }
        log.log(line, tag: tag)
    }

    /// Why the state machine did not begin a change of quality, in words.
    private func refusal(for quality: String) -> String {
        let s = coordinator.state
        if !s.isSteady { return "it is \(Self.phase(s.phase)), and a change begins only from playing, paused or buffering" }
        if s.swap != nil { return "a replacement is on its way already" }
        if s.quality?.id == quality { return "that is the quality it has" }
        if let last = s.lastQualityChange {
            return "the last change was \(Self.seconds(clock() - last)) ago and the cooldown is \(Self.seconds(coordinator.policy.qualityCooldown))"
        }
        return "unknown"
    }

    /// The app has replaced the item without the state machine having a change under way: it is a new session as far as the state machine
    /// goes, and the viewer's wish stays what it was.
    private func followAsNewSession() {
        let s = coordinator.state
        coordinator.send(.reload(startAt: s.position, selection: s.selection, quality: s.quality))
    }

    // MARK: - Words

    static func seconds(_ value: TimeInterval) -> String {
        value.isFinite ? String(format: "%.1f s", value) : "-"
    }

    static func phase(_ phase: Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .loading: return "loading"
        case .playing: return "playing"
        case .paused: return "paused"
        case .buffering: return "buffering"
        case .seeking: return "seeking"
        case .switching: return "switching"
        case .failed(let reason): return "failed (\(reason))"
        case .stopped: return "stopped"
        }
    }

    static func describe(_ app: Observation) -> String {
        var parts: [String] = []
        parts.append(app.wantsToPlay ? "wants to play" : "paused by the viewer")
        if app.isWaitingForData { parts.append("waiting for data") }
        if app.isReconnecting { parts.append("reconnecting") }
        if app.hasFailed { parts.append("failed") }
        if app.isChangingQuality { parts.append("changing the quality") }
        if app.hasUnsentJump { parts.append("a jump not sent yet") }
        return parts.joined(separator: ", ")
    }

    static func describe(_ event: PlaybackEvent) -> String {
        switch event {
        case let .load(source, startAt, selection, quality):
            return "load \(source.id) at \(seconds(startAt))\(describe(selection))" + (quality.map { ", quality \($0.id)" } ?? "")
        case .play: return "play"
        case .pause: return "pause"
        case let .reload(startAt, selection, quality): return "reload at \(seconds(startAt))\(describe(selection))" + (quality.map { ", quality \($0.id)" } ?? "")
        case let .seek(target): return "seek to \(seconds(target))"
        case let .selectAudio(track): return "audio \(track.map { "#\($0)" } ?? "default")"
        case let .selectSubtitle(track): return "subtitles \(track.map { "#\($0)" } ?? "off")"
        case let .requestQuality(choice, _): return "quality \(choice.id) requested"
        case .stop: return "stop"
        case let .engineReady(e): return "player ready (epoch \(e.rawValue))"
        case let .engineFailed(e, reason): return "player failed (epoch \(e.rawValue)): \(reason)"
        case let .engineStalled(e): return "player stalled (epoch \(e.rawValue))"
        case let .engineRecovered(e): return "player recovered (epoch \(e.rawValue))"
        case let .engineTick(e, position): return "tick \(seconds(position)) (epoch \(e.rawValue))"
        case let .seekFinished(e, token): return "jump landed (epoch \(e.rawValue), jump #\(token.rawValue))"
        case let .swapPrepared(e): return "replacement #\(e.rawValue) ready"
        case let .swapFailed(e, reason): return "replacement #\(e.rawValue) failed: \(reason)"
        case let .swapFinished(e): return "replacement #\(e.rawValue) is at its place"
        }
    }

    private static func describe(_ selection: TrackSelection) -> String {
        var text = ""
        if let audio = selection.audio { text += ", audio #\(audio)" }
        if let subtitle = selection.subtitle { text += ", subtitles #\(subtitle)" }
        return text
    }

    static func describe(_ effect: PlaybackEffect) -> String {
        switch effect {
        case let .load(e, source, startAt, _, _): return "load #\(e.rawValue) \(source.id) at \(seconds(startAt))"
        case let .play(e): return "play #\(e.rawValue)"
        case let .pause(e): return "pause #\(e.rawValue)"
        case let .seek(e, token, target): return "seek #\(e.rawValue) jump \(token.rawValue) to \(seconds(target))"
        case let .applySelection(e, selection): return "tracks #\(e.rawValue)\(describe(selection))"
        case let .prepareSwap(e, quality, startAt, _): return "prepare #\(e.rawValue) \(quality.id) from \(seconds(startAt))"
        case let .commitSwap(e, replacing, at, _): return "take over #\(e.rawValue) from #\(replacing.rawValue) at \(seconds(at))"
        case let .discardSwap(e): return "discard #\(e.rawValue)"
        case let .stop(e): return "stop #\(e.rawValue)"
        }
    }
}
