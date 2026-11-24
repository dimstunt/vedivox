import AVFoundation
import XCTest

/// Reading the tail of a recording while it is still being written (change
/// `live-speakers`, design D3): the header's sizes are not final, the audio is.
final class RecordingTailTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A writer as the microphone capture opens it: 48 kHz mono Float32.
    private func writer(_ url: URL) throws -> (file: AVAudioFile, format: AVAudioFormat) {
        let format = try XCTUnwrap(AudioConverter.float32Format(channels: 1, sampleRate: 48000))
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        return (file, format)
    }

    /// Sample `n` of the recording is n / 1 000 000: every sample tells where it came from.
    private func write(frames: Range<Int>, to file: AVAudioFile, _ format: AVAudioFormat) throws {
        for start in stride(from: frames.lowerBound, to: frames.upperBound, by: 4800) {
            let count = min(4800, frames.upperBound - start)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0 ..< count { data[0][frame] = Float(start + frame) / 1_000_000 }
            try file.write(from: buffer)
        }
    }

    /// Read to the end: one `read(into:)` sized to the file's length stops a
    /// block short of it (95 232 of 96 000 frames on macOS 26).
    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        var samples: [Float] = []
        while file.framePosition < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536))
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples += UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength))
        }
        return samples
    }

    /// Everything a reader of the tail gives out, block by block as the converter asks.
    private func samples(_ reader: RecordingTail.Reader) throws -> [[Float]] {
        var channels = [[Float]](repeating: [], count: Int(reader.processingFormat.channelCount))
        while reader.framePosition < reader.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096))
            try reader.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let data = try XCTUnwrap(buffer.floatChannelData)
            for channel in channels.indices {
                channels[channel] += UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength))
            }
        }
        return channels
    }

    func testTheTailOfAFileStillBeingWrittenIsWhatWasWritten() throws {
        let recording = directory.appendingPathComponent("mic.wav")
        let (file, format) = try writer(recording)
        try write(frames: 0 ..< 144_000, to: file, format)

        // The writer is still open: nothing has finalized the header, and a
        // reader that trusts it finds no audio at all.
        XCTAssertEqual(try AVAudioFile(forReading: recording).length, 0)
        let reader = try RecordingTail.Reader(last: 1, of: recording)
        let tail = reader.tail
        let copied = try samples(reader)[0]

        XCTAssertEqual(tail.duration, 1, accuracy: 0.001)
        XCTAssertEqual(copied.count, 48000)
        let first = Int((copied[0] * 1_000_000).rounded())
        XCTAssertEqual(tail.from, Double(first) / 48000, accuracy: 0.001, "the tail knows where in the recording it starts")
        for (index, sample) in copied.enumerated() where index % 997 == 0 {
            XCTAssertEqual(sample, Float(first + index) / 1_000_000, accuracy: 1e-7, "whole frames, in order")
        }
        // The writer holds nothing back: the tail ends with the last frame written.
        XCTAssertEqual(first + copied.count, 144_000)

        // …and the recording goes on, untouched by the reading.
        try write(frames: 144_000 ..< 192_000, to: file, format)
        reader.rewind()
        XCTAssertEqual(try samples(reader)[0], copied, "a second read is the same stretch, not what has been added since")
        let later = try RecordingTail.Reader(last: 0.5, of: recording).tail
        XCTAssertGreaterThan(later.from, tail.from)
        _ = file
    }

    func testAfterTheWriterClosesTheWholeRecordingIsStillThere() throws {
        let recording = directory.appendingPathComponent("mic.wav")
        do {
            let (file, format) = try writer(recording)
            try write(frames: 0 ..< 96000, to: file, format)
            _ = try RecordingTail.convert(last: 1, of: recording, to: directory.appendingPathComponent("tail.wav"))
        }
        XCTAssertEqual(try samples(recording).count, 96000, "reading the tail cost the recording nothing")
    }

    /// A header as a crashed or a running writer leaves it: sizes of zero.
    /// Channel `c` of frame `n` is n + c / 10.
    private func raw(frames: Int, channels: UInt16 = 2, format: UInt16 = 3, trailingBytes: Int = 0) -> Data {
        func bytes<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var data = Data("RIFF".utf8) + bytes(UInt32(0)) + Data("WAVE".utf8)
        data += Data("fmt ".utf8) + bytes(UInt32(16)) + bytes(format) + bytes(channels) + bytes(UInt32(16000))
        data += bytes(UInt32(16000) * UInt32(channels) * 4) + bytes(channels * 4) + bytes(UInt16(32))
        data += Data("FLLR".utf8) + bytes(UInt32(6)) + Data(count: 6)
        data += Data("data".utf8) + bytes(UInt32(0))
        for frame in 0 ..< frames {
            for channel in 0 ..< channels { data += bytes((Float(frame) + Float(channel) / 10).bitPattern) }
        }
        return data + Data(count: trailingBytes)
    }

    func testTheSizesInTheHeaderAreNotTrusted() throws {
        let recording = directory.appendingPathComponent("system.wav")
        // Two seconds of stereo, and half a frame the writer was in the middle of.
        try raw(frames: 32000, trailingBytes: 4).write(to: recording)

        let reader = try RecordingTail.Reader(last: 0.5, of: recording)

        XCTAssertEqual(reader.tail, .init(from: 1.5, duration: 0.5))
        XCTAssertEqual(reader.processingFormat.sampleRate, 16000)
        let channels = try samples(reader)
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0], (24000 ..< 32000).map { Float($0) })
        XCTAssertEqual(channels[1], (24000 ..< 32000).map { Float($0) + 0.1 }, "each channel gets its own samples")
    }

    /// The point of the tail: nothing but the 16-bit recognition file is written.
    func testTheTailIsConvertedWithoutACopy() throws {
        let recording = directory.appendingPathComponent("mic.wav")
        let output = directory.appendingPathComponent("tail.wav")
        let (file, format) = try writer(recording)
        try write(frames: 0 ..< 144_000, to: file, format)

        let tail = try RecordingTail.convert(last: 1, of: recording, to: output)

        XCTAssertEqual(tail.duration, 1, accuracy: 0.001)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["mic.wav", "tail.wav"])
        let result = try AVAudioFile(forReading: output)
        XCTAssertEqual(result.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(Double(result.length) / 16000, 1, accuracy: 0.05)
        _ = file
    }

    func testATailLongerThanTheRecordingIsTheWholeRecording() throws {
        let recording = directory.appendingPathComponent("system.wav")
        try raw(frames: 16000).write(to: recording)
        XCTAssertEqual(try RecordingTail.Reader(last: 300, of: recording).tail, .init(from: 0, duration: 1))
    }

    func testARecordingWithNoAudioYetAndAFileThatIsNotOneAreRefused() throws {
        let empty = directory.appendingPathComponent("empty.wav")
        try raw(frames: 0).write(to: empty)
        XCTAssertThrowsError(try RecordingTail.Reader(last: 5, of: empty)) {
            XCTAssertEqual($0 as? RecordingTail.Failure, .noAudioYet)
        }
        let text = directory.appendingPathComponent("notes.wav")
        try Data("not audio at all".utf8).write(to: text)
        XCTAssertThrowsError(try RecordingTail.Reader(last: 5, of: text)) {
            XCTAssertEqual($0 as? RecordingTail.Failure, .notAWAVFile)
        }
        let integers = directory.appendingPathComponent("integers.wav")
        try raw(frames: 16000, format: 1).write(to: integers)
        XCTAssertThrowsError(try RecordingTail.Reader(last: 5, of: integers)) {
            XCTAssertEqual($0 as? RecordingTail.Failure, .notFloat32)
        }
    }
}
