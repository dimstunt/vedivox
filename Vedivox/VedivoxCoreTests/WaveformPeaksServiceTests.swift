import AVFoundation
import XCTest

final class WaveformPeaksServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformPeaksTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeWAV(samples: [Float], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    func testPeaksReflectSignalEnergyAndCache() throws {
        // 1s silence + 1s loud sine at 16 kHz.
        let rate = 16000.0
        let silence = [Float](repeating: 0, count: Int(rate))
        let sine = (0 ..< Int(rate)).map { Float(sin(2.0 * .pi * 440 * Double($0) / rate)) * 0.9 }
        let url = tempDir.appendingPathComponent("mic.wav")
        try writeWAV(samples: silence + sine, rate: rate, to: url)

        let peaks = WaveformPeaksService.load(micURL: url, systemURL: nil, binCount: 10)
        let mic = try XCTUnwrap(peaks?.mic)
        XCTAssertEqual(mic.count, 10)
        XCTAssertEqual(peaks?.duration ?? 0, 2.0, accuracy: 0.01)

        // First half ≈ silence, second half loud (normalized to ~1).
        for bin in 0 ..< 5 { XCTAssertLessThan(mic[bin], 0.05, "bin \(bin) should be silent") }
        for bin in 5 ..< 10 { XCTAssertGreaterThan(mic[bin], 0.8, "bin \(bin) should be loud") }

        // Cache file created next to the audio; second load returns identical peaks.
        let cacheURL = tempDir.appendingPathComponent("waveform-peaks.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        let reloaded = WaveformPeaksService.load(micURL: url, systemURL: nil, binCount: 10)
        XCTAssertEqual(reloaded, peaks)
    }

    func testMixIsElementwiseMaxAndShorterTrackPadsWithZeros() throws {
        let rate = 16000.0
        // mic: 2s, loud only in first second; system: 1s, loud throughout.
        let micSamples = (0 ..< Int(rate)).map { _ in Float(0.8) } + [Float](repeating: 0, count: Int(rate))
        let sysSamples = [Float](repeating: 0.4, count: Int(rate))
        let micURL = tempDir.appendingPathComponent("mic.wav")
        let sysURL = tempDir.appendingPathComponent("system.wav")
        try writeWAV(samples: micSamples, rate: rate, to: micURL)
        try writeWAV(samples: sysSamples, rate: rate, to: sysURL)

        let peaks = try XCTUnwrap(
            WaveformPeaksService.load(micURL: micURL, systemURL: sysURL, binCount: 4)
        )
        let system = try XCTUnwrap(peaks.system)
        let mix = try XCTUnwrap(peaks.peaks(for: .mix))

        // Timeline = 2s (mic); system occupies only the first half, rest is 0.
        XCTAssertGreaterThan(system[0], 0.1)
        XCTAssertEqual(system[2], 0)
        XCTAssertEqual(system[3], 0)
        // Mix = max: first half dominated by mic (0.8 > 0.4), second half 0.
        XCTAssertEqual(mix[0], peaks.mic![0])
        XCTAssertEqual(mix[3], 0)
    }
}
