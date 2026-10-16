import Foundation

/// What the routing decision needs to know about a source, independent of
/// any server's model types. The app maps its own media-source type to this.
public struct SourceTraits: Equatable, Sendable {
    public struct AudioTrack: Equatable, Sendable {
        public var index: Int
        public var codec: String?
        public init(index: Int, codec: String?) {
            self.index = index
            self.codec = codec
        }
    }

    public var container: String?
    public var videoCodec: String?
    /// HEVC level as the server reports it (153 is level 5.1).
    public var videoLevel: Int?
    public var audioTracks: [AudioTrack]

    public init(container: String?, videoCodec: String?, videoLevel: Int?, audioTracks: [AudioTrack]) {
        self.container = container
        self.videoCodec = videoCodec
        self.videoLevel = videoLevel
        self.audioTracks = audioTracks
    }
}

public enum RemuxEligibility {
    /// Whether the local remux engine should take this source at all.
    ///
    /// Moved here unchanged from the two app targets, where it had
    /// identical logic and diverging comments.
    ///
    /// - Parameter audioStreamIndex: the track that will actually play, so an
    ///   unselected commentary track cannot veto the source.
    /// - Parameter allowMultichannelPassthrough: with it off, H.264 + AC-3/E-AC-3
    ///   stays on the server's own transcode. Raw multichannel bitstreams come
    ///   out as distorted noise on output paths without a receiver to decode
    ///   them, and H.264 has a known-good server path to fall back to. HEVC has
    ///   none (the server's HLS packaging is broken for it), so it always goes
    ///   through the engine, with the audio bridged.
    public static func shouldHandle(
        _ source: SourceTraits,
        audioStreamIndex: Int?,
        allowMultichannelPassthrough: Bool = false
    ) -> Bool {
        let container = source.container?.lowercased()
        // Files AVFoundation opens natively need no remux.
        guard !["mp4", "m4v", "mov"].contains(container ?? "") else { return false }
        guard let videoCodec = source.videoCodec?.lowercased(),
              ["h264", "hevc"].contains(videoCodec) else { return false }
        // Beyond what the hardware decoder handles, remuxing cannot help.
        if videoCodec == "hevc", let level = source.videoLevel, level > 153 {
            return false
        }
        if videoCodec == "h264", !allowMultichannelPassthrough {
            // Mirrors the original lookup exactly: a selected track without a
            // codec falls back to the first track's codec.
            let selected = source.audioTracks.first(where: { $0.index == audioStreamIndex })?.codec?.lowercased()
                ?? source.audioTracks.first?.codec?.lowercased()
            if let selected, ["ac3", "eac3"].contains(selected) {
                return false
            }
        }
        return true
    }
}
