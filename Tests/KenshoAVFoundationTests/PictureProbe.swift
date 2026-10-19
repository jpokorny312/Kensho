import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// The number of a frame, drawn into the picture of the test stream (`HLSFixture.Picture`) as sixteen blocks of black and white along the top edge: the
/// writer draws it, `PictureProbe` reads it back from what the player has decoded. A test can then say which frame of the film the player shows after a
/// jump, a stall or a swap - not only where its clock stands, which a picture that is late or missing leaves as it was.
enum PictureCode {
    static let bits = 16
    /// A block is one macroblock of the encoder: black and white edges inside it would smear, and the centre of the block stays what it was drawn as.
    static let block = 16

    /// Draws `number` into a 32-bit BGRA buffer, the rest of it black.
    static func draw(_ number: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rows = CVPixelBufferGetHeight(buffer), width = CVPixelBufferGetWidth(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0, stride * rows)
        for bit in 0..<bits where (number >> (bits - 1 - bit)) & 1 == 1 {
            for y in 0..<min(block, rows) {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in (bit * block)..<min((bit + 1) * block, width) {
                    row[x * 4] = 255; row[x * 4 + 1] = 255; row[x * 4 + 2] = 255; row[x * 4 + 3] = 255
                }
            }
        }
    }

    /// The number drawn into a 32-bit BGRA buffer, read at the centre of each block.
    static func number(in buffer: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetWidth(buffer) >= bits * block, CVPixelBufferGetHeight(buffer) >= block else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: (block / 2) * stride).assumingMemoryBound(to: UInt8.self)
        var number = 0
        for bit in 0..<bits {
            let pixel = row.advanced(by: (bit * block + block / 2) * 4)
            let brightness = (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
            number = number << 1 | (brightness > 127 ? 1 : 0)
        }
        return number
    }
}

/// Reads the number of the frame a player shows. An `AVPlayerItemVideoOutput` on the item is what a view is to a player: it is handed the decoded frames,
/// here without a screen. (Added before the item plays, or at any time: it holds the frames from then on.)
///
/// A frame is handed over once; `latest` is the last that came, and `forget()` before an action makes a test wait for a frame that the action brought.
@MainActor
final class PictureProbe {
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    /// The number of the frame that came last (nil: none since the start or the last `forget()`).
    private(set) var latest: Int?
    /// Every frame number seen, in order of arrival (a frame twice in a row is there once).
    private(set) var seen: [Int] = []

    init(item: AVPlayerItem) {
        self.item = item
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
    }

    deinit { item.remove(output) }

    func forget() {
        latest = nil
        seen.removeAll()
    }

    /// Takes the frame the player has ready for the item's current time, if a new one is; returns what is shown now.
    @discardableResult
    func poll() -> Int? {
        let time = item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
           let number = PictureCode.number(in: buffer) {
            latest = number
            if seen.last != number { seen.append(number) }
        }
        return latest
    }
}
