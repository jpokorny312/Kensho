import Foundation
import AVFoundation

/// Short media files written at test time, so the engine is exercised against
/// a real `AVPlayer` without shipping binary fixtures.
enum TestMedia {
    /// An AAC file of silence: a test run must not make a sound on the machine
    /// it runs on, and `AVPlayer` plays silence exactly as it plays music.
    static func silentAudio(seconds: Double, in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent("\(name).m4a")
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        // The file is finished when the `AVAudioFile` goes away, so it lives only in this scope.
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let chunk: AVAudioFrameCount = 44_100
        var remaining = AVAudioFrameCount(seconds * sampleRate)
        while remaining > 0 {
            let frames = min(chunk, remaining)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames  // a fresh buffer is zeroed: silence
            try file.write(from: buffer)
            remaining -= frames
        }
        return url
    }

    /// A folder of its own for one test, removed afterwards.
    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kensho-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
