import AVFoundation
import XCTest

final class AudioRateCorrectorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRateCorrectorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Generate a sine of `frequency` Hz sampled at `sampleRate`, `seconds` long.
    private func sine(frequency: Double, sampleRate: Double, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0 ..< count).map { Float(sin(2.0 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// Write mono Float32 samples as a WAV claiming `headerRate`.
    private func writeWAV(samples: [Float], headerRate: Double, to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: headerRate, channels: 1, interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: headerRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private func readAll(url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
        return (samples, file.processingFormat.sampleRate)
    }

    /// Estimate dominant frequency by zero-crossing count.
    private func zeroCrossingFrequency(_ samples: ArraySlice<Float>, sampleRate: Double) -> Double {
        var crossings = 0
        var prev = samples.first ?? 0
        for s in samples.dropFirst() {
            if (prev < 0 && s >= 0) || (prev >= 0 && s < 0) { crossings += 1 }
            prev = s
        }
        let seconds = Double(samples.count) / sampleRate
        return Double(crossings) / 2.0 / seconds
    }

    func testHalvedRateTailIsStretchedAndPitchRestored() throws {
        // Head: 2s of 440 Hz correctly sampled at 48k.
        // Tail: 2s of real-world 440 Hz audio captured at 24k (48000 samples),
        // appended raw — played at the 48k header rate it lasts 1s and sounds like 880 Hz.
        let head = sine(frequency: 440, sampleRate: 48000, seconds: 2)
        let tail = sine(frequency: 440, sampleRate: 24000, seconds: 2)
        let url = tempDir.appendingPathComponent("halved.wav")
        try writeWAV(samples: head + tail, headerRate: 48000, to: url)

        let segments = [
            RateSegment(startFrame: 0, rate: 48000),
            RateSegment(startFrame: Int64(head.count), rate: 23980), // measured, slightly off
        ]
        let changed = try AudioRateCorrector.correctInPlace(url: url, segments: segments)
        XCTAssertTrue(changed)

        let (samples, rate) = try readAll(url: url)
        XCTAssertEqual(rate, 48000)
        // 2s head + 2s restored tail ≈ 4s total.
        XCTAssertEqual(Double(samples.count) / rate, 4.0, accuracy: 0.05)

        // Head untouched: still 440 Hz.
        let headFreq = zeroCrossingFrequency(samples[10_000 ..< 86_000], sampleRate: rate)
        XCTAssertEqual(headFreq, 440, accuracy: 5)
        // Tail resampled: 440 Hz at normal speed (was 880 Hz before correction).
        let tailFreq = zeroCrossingFrequency(samples[(samples.count - 80_000) ..< (samples.count - 4_000)], sampleRate: rate)
        XCTAssertEqual(tailFreq, 440, accuracy: 5)
    }

    func testAllSegmentsAtHeaderRateLeaveFileUntouched() throws {
        let samples = sine(frequency: 440, sampleRate: 48000, seconds: 1)
        let url = tempDir.appendingPathComponent("steady.wav")
        try writeWAV(samples: samples, headerRate: 48000, to: url)
        let originalSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int

        // Measured rates jitter slightly but snap to the header rate — no correction.
        let segments = [
            RateSegment(startFrame: 0, rate: 47992),
            RateSegment(startFrame: 24_000, rate: 48011),
        ]
        let changed = try AudioRateCorrector.correctInPlace(url: url, segments: segments)

        XCTAssertFalse(changed)
        let newSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertEqual(newSize, originalSize)
    }

    func testNearestStandardRateSnapping() {
        XCTAssertEqual(AudioRateCorrector.nearestStandardRate(23980), 24000)
        XCTAssertEqual(AudioRateCorrector.nearestStandardRate(44080), 44100)
        XCTAssertEqual(AudioRateCorrector.nearestStandardRate(48020), 48000)
        XCTAssertEqual(AudioRateCorrector.nearestStandardRate(15990), 16000)
    }
}
