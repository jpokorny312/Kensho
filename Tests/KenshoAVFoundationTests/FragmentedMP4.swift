import Foundation

/// Just enough of the fragmented MPEG-4 that `AVAssetWriter` writes for HLS to read the things a test must not take on trust from the encoder: where the
/// samples of a segment are and which of them can be jumped to (`HLSFixture` has a picture whose keyframes are what the player lands on).
///
/// Boxes are walked by their size; only the ones below are looked into: `moov/trak/mdia/mdhd` (the timescale) and `moof/traf/{tfhd,tfdt,trun}`
/// (decode time, sample durations and flags). Anything else - `styp`, `sidx`, `mdat` - is stepped over.
enum FragmentedMP4 {
    struct Sample: Equatable {
        /// Presentation time in seconds.
        var time: TimeInterval
        var duration: TimeInterval
        /// A sample the decoder can start at (a keyframe): `sample_is_non_sync_sample` is not set.
        var isSync: Bool
    }

    private struct Box {
        var type: String
        var content: Range<Int>
    }

    /// The timescale of the track of an initialization segment (ticks per second), or nil when there is no `mdhd` to read.
    static func timescale(initialization: Data) -> UInt32? {
        let bytes = [UInt8](initialization)
        guard let moov = boxes(in: bytes, 0..<bytes.count).first(where: { $0.type == "moov" }),
              let trak = boxes(in: bytes, moov.content).first(where: { $0.type == "trak" }),
              let mdia = boxes(in: bytes, trak.content).first(where: { $0.type == "mdia" }),
              let mdhd = boxes(in: bytes, mdia.content).first(where: { $0.type == "mdhd" }) else { return nil }
        // version 1 has 64-bit creation and modification times
        let at = mdhd.content.lowerBound + (bytes[mdhd.content.lowerBound] == 1 ? 20 : 12)
        guard at + 4 <= mdhd.content.upperBound else { return nil }
        return u32(bytes, at)
    }

    /// The samples of a media segment (`moof` + `mdat`) in decode order, with their presentation times.
    static func samples(in segment: Data, timescale: UInt32) -> [Sample] {
        let bytes = [UInt8](segment)
        let scale = Double(timescale)
        var result: [Sample] = []
        for moof in boxes(in: bytes, 0..<bytes.count) where moof.type == "moof" {
            for traf in boxes(in: bytes, moof.content) where traf.type == "traf" {
                var defaultDuration: UInt32 = 0
                var defaultFlags: UInt32 = 0
                var decodeTime: Int64 = 0
                for box in boxes(in: bytes, traf.content) {
                    let c = box.content.lowerBound
                    switch box.type {
                    case "tfhd":
                        let flags = u32(bytes, c) & 0x00FF_FFFF
                        var at = c + 8      // version + flags, track id
                        if flags & 0x1 != 0 { at += 8 }
                        if flags & 0x2 != 0 { at += 4 }
                        if flags & 0x8 != 0 { defaultDuration = u32(bytes, at); at += 4 }
                        if flags & 0x10 != 0 { at += 4 }
                        if flags & 0x20 != 0 { defaultFlags = u32(bytes, at) }
                    case "tfdt":
                        decodeTime = bytes[c] == 1 ? Int64(bitPattern: u64(bytes, c + 4)) : Int64(u32(bytes, c + 4))
                    case "trun":
                        let version = bytes[c]
                        let flags = u32(bytes, c) & 0x00FF_FFFF
                        let count = Int(u32(bytes, c + 4))
                        var at = c + 8
                        if flags & 0x1 != 0 { at += 4 }
                        var firstFlags: UInt32?
                        if flags & 0x4 != 0 { firstFlags = u32(bytes, at); at += 4 }
                        for index in 0..<count {
                            var duration = defaultDuration
                            var sampleFlags = defaultFlags
                            var offset: Int64 = 0
                            if flags & 0x100 != 0 { duration = u32(bytes, at); at += 4 }
                            if flags & 0x200 != 0 { at += 4 }
                            if flags & 0x400 != 0 { sampleFlags = u32(bytes, at); at += 4 }
                            if flags & 0x800 != 0 {
                                let raw = u32(bytes, at)
                                offset = version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
                                at += 4
                            }
                            if index == 0, let firstFlags { sampleFlags = firstFlags }
                            result.append(Sample(
                                time: Double(decodeTime + offset) / scale,
                                duration: Double(duration) / scale,
                                isSync: sampleFlags & 0x0001_0000 == 0
                            ))
                            decodeTime += Int64(duration)
                        }
                    default:
                        break
                    }
                }
            }
        }
        return result
    }

    /// `avc1.PPCCLL` of an AVC initialization segment (profile, constraint flags and level out of the `avcC` box), the string a master playlist names in
    /// `CODECS`; nil for anything else.
    static func avcCodecString(initialization: Data) -> String? {
        let bytes = [UInt8](initialization)
        let marker = Array("avcC".utf8)
        guard bytes.count > marker.count + 4 else { return nil }
        for start in 0...(bytes.count - marker.count - 4) where Array(bytes[start..<start + marker.count]) == marker {
            let c = start + marker.count      // configurationVersion, then profile, compatibility, level
            return String(format: "avc1.%02X%02X%02X", bytes[c + 1], bytes[c + 2], bytes[c + 3])
        }
        return nil
    }

    // MARK: - Boxes

    private static func boxes(in bytes: [UInt8], _ range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            var size = Int(u32(bytes, at))
            var header = 8
            if size == 1 {
                guard at + 16 <= range.upperBound else { break }
                size = Int(truncatingIfNeeded: u64(bytes, at + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - at
            }
            guard size >= header, at + size <= range.upperBound else { break }
            result.append(Box(type: String(decoding: bytes[at + 4..<at + 8], as: UTF8.self), content: (at + header)..<(at + size)))
            at += size
        }
        return result
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    private static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        UInt64(u32(b, at)) << 32 | UInt64(u32(b, at + 4))
    }
}
