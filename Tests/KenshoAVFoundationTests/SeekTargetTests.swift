import XCTest
@testable import KenshoAVFoundation

final class SeekTargetTests: XCTestCase {
    func testATargetInsideTheItemIsLeftAlone() {
        XCTAssertEqual(SeekTarget.clamped(120, seekableEnd: 1_800, duration: 1_800), 120)
    }

    func testATargetPastTheEndGoesToTheEnd() {
        XCTAssertEqual(SeekTarget.clamped(5_000, seekableEnd: 1_800, duration: 1_800), 1_800)
    }

    func testTheSeekableRangeWinsOverTheDuration() {
        // A stream that is not seekable to its very end (or still growing): what is seekable is what counts.
        XCTAssertEqual(SeekTarget.clamped(1_790, seekableEnd: 1_500, duration: 1_800), 1_500)
    }

    func testWithoutARangeTheDurationCounts() {
        XCTAssertEqual(SeekTarget.clamped(9_000, seekableEnd: nil, duration: 1_800), 1_800)
    }

    func testAnItemWithNoEndKnownLeavesTheTargetAlone() {
        XCTAssertEqual(SeekTarget.clamped(9_000, seekableEnd: nil, duration: nil), 9_000)
        XCTAssertEqual(SeekTarget.clamped(9_000, seekableEnd: .infinity, duration: .infinity), 9_000, "a live stream")
    }

    func testNegativeAndNonsenseTargetsGoToTheStart() {
        XCTAssertEqual(SeekTarget.clamped(-5, seekableEnd: 100, duration: 100), 0)
        XCTAssertEqual(SeekTarget.clamped(.nan, seekableEnd: 100, duration: 100), 0)
    }
}
