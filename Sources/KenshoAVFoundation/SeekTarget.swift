import Foundation

/// Where a jump may go. AVPlayerItem.h: a seek outside `seekableTimeRanges` is cancelled and its completion handler gets `finished == false` - the same
/// answer as for a jump that something else interrupted, which the engine tries again and finally takes for a dead session. A local file clamps to its
/// end by itself (the engine tests jump to 5 000 s in a film of 30); a stream is not promised to, so the target is cut to what the item says is seekable.
enum SeekTarget {
    /// - Parameters:
    ///   - seekableEnd: the end of the last seekable range, if the item has one.
    ///   - duration: the duration of the item, if it is finite.
    static func clamped(_ seconds: TimeInterval, seekableEnd: TimeInterval?, duration: TimeInterval?) -> TimeInterval {
        var upper = TimeInterval.infinity
        if let seekableEnd, seekableEnd.isFinite, seekableEnd > 0 {
            upper = seekableEnd
        } else if let duration, duration.isFinite, duration > 0 {
            upper = duration
        }
        guard seconds.isFinite else { return 0 }
        return max(0, min(seconds, upper))
    }
}
