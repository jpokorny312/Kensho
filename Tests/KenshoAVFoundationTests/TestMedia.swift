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

    /// A QuickTime movie with two alternative audio tracks (English and German, both silent) in one group of alternates: AVFoundation offers them as
    /// the options of one `AVMediaSelectionGroup`, as it does the audio renditions of a stream. The tracks are the same silence - what a test looks at is
    /// which option is selected, not what it sounds like.
    static func silentMovieWithTwoAudioTracks(seconds: Double, in directory: URL, name: String) async throws -> URL {
        let source = try silentAudio(seconds: seconds, in: directory, name: "\(name)-source")
        let url = directory.appendingPathComponent("\(name).mov")
        let asset = AVURLAsset(url: source)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        func input(language: String) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
            ])
            input.languageCode = language
            input.extendedLanguageTag = language == "eng" ? "en" : "de"
            return input
        }
        let english = input(language: "eng"), german = input(language: "deu")
        writer.add(english)
        writer.add(german)
        writer.add(AVAssetWriterInputGroup(inputs: [english, german], defaultInput: english))
        guard reader.startReading(), writer.startWriting() else { throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        while let buffer = output.copyNextSampleBuffer() {
            while !english.isReadyForMoreMediaData || !german.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            english.append(buffer)
            german.append(buffer)
        }
        english.markAsFinished()
        german.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    /// A folder of its own for one test, removed afterwards.
    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kensho-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
