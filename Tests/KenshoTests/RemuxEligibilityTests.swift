import XCTest
@testable import Kensho

final class RemuxEligibilityTests: XCTestCase {
    private func traits(
        container: String? = "matroska",
        video: String? = "hevc",
        level: Int? = 150,
        audio: [(Int, String?)] = [(1, "eac3")]
    ) -> SourceTraits {
        SourceTraits(
            container: container, videoCodec: video, videoLevel: level,
            audioTracks: audio.map { SourceTraits.AudioTrack(index: $0.0, codec: $0.1) }
        )
    }

    func testNativeContainersAreNotRemuxed() {
        for c in ["mp4", "M4V", "mov"] {
            XCTAssertFalse(RemuxEligibility.shouldHandle(traits(container: c), audioStreamIndex: 1), c)
        }
    }

    func testOnlyH264AndHEVCAreHandled() {
        XCTAssertFalse(RemuxEligibility.shouldHandle(traits(video: "vp9"), audioStreamIndex: 1))
        XCTAssertFalse(RemuxEligibility.shouldHandle(traits(video: nil), audioStreamIndex: 1))
        XCTAssertTrue(RemuxEligibility.shouldHandle(traits(video: "h264", audio: [(1, "aac")]), audioStreamIndex: 1))
    }

    func testHEVCAboveLevel153IsRefused() {
        XCTAssertTrue(RemuxEligibility.shouldHandle(traits(level: 153), audioStreamIndex: 1))
        XCTAssertFalse(RemuxEligibility.shouldHandle(traits(level: 156), audioStreamIndex: 1))
    }

    func testH264WithAC3IsVetoedUnlessPassthroughAllowed() {
        let t = traits(video: "h264", audio: [(1, "ac3")])
        XCTAssertFalse(RemuxEligibility.shouldHandle(t, audioStreamIndex: 1))
        XCTAssertTrue(RemuxEligibility.shouldHandle(t, audioStreamIndex: 1, allowMultichannelPassthrough: true))
    }

    func testHEVCWithEAC3IsAlwaysHandled() {
        XCTAssertTrue(RemuxEligibility.shouldHandle(traits(video: "hevc", audio: [(1, "eac3")]), audioStreamIndex: 1))
    }

    func testUnselectedCommentaryTrackDoesNotVeto() {
        let t = traits(video: "h264", audio: [(1, "aac"), (2, "ac3")])
        XCTAssertTrue(RemuxEligibility.shouldHandle(t, audioStreamIndex: 1))
        XCTAssertFalse(RemuxEligibility.shouldHandle(t, audioStreamIndex: 2))
    }

    func testNoSelectedIndexFallsBackToFirstTrack() {
        let t = traits(video: "h264", audio: [(1, "eac3"), (2, "aac")])
        XCTAssertFalse(RemuxEligibility.shouldHandle(t, audioStreamIndex: nil))
        XCTAssertFalse(RemuxEligibility.shouldHandle(t, audioStreamIndex: 99))
    }
}
