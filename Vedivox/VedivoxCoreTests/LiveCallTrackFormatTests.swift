import AVFoundation
import os
import XCTest

/// The call track in the format the capture writes on a stereo output device
/// — 48 kHz, two channels, Float32, interleaved, 512-frame tap buffers
/// Live text hears it twice: through the sink on the tap, and
/// through the tail of the file while it is still being written. Both must
/// get the sound that was played, at its pitch, its length and from either
/// channel.
final class LiveCallTrackFormatTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-call-track-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let tapFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true
    )!

    /// The file as `SystemAudioCapture.start` opens it for that tap.
    private func writer(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: true
        )
    }

    /// `seconds` of tap buffers with a 440 Hz tone of the given amplitudes.
    private func buffers(seconds: Double, left: Float, right: Float) throws -> [AVAudioPCMBuffer] {
        try stride(from: 0, to: Int(seconds * 48000), by: 512).map { start in
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: Self.tapFormat, frameCapacity: 512))
            buffer.frameLength = 512
            let data = try XCTUnwrap(buffer.floatChannelData)[0]
            for frame in 0 ..< 512 {
                let tone = sinf(2 * .pi * 440 * Float(start + frame) / 48000)
                data[2 * frame] = left * tone
                data[2 * frame + 1] = right * tone
            }
            return buffer
        }
    }

    /// What the quick pass gets: the sink's 16 kHz mono.
    private func heardOnTheTap(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        let collected = OSAllocatedUnfairLock(initialState: [Float]())
        let sink = LiveAudioSink(onSamples: { samples in collected.withLock { $0.append(contentsOf: samples) } })
        for buffer in buffers { sink.feed(buffer) }
        return collected.withLock { $0 }
    }

    /// What a precise pass gets: the last `seconds` of the file the buffers
    /// went to, read while the writer is open, as the pipeline converts it.
    private func heardInTheFile(_ buffers: [AVAudioPCMBuffer], last seconds: Double) async throws -> [Float] {
        let recording = directory.appendingPathComponent("system.wav")
        let file = try writer(recording)
        for buffer in buffers { try file.write(from: buffer) }
        XCTAssertEqual(try AVAudioFile(forReading: recording).length, 0, "the writer is open: the header holds no sizes yet")

        let tail = directory.appendingPathComponent("tail.wav")
        let converted = directory.appendingPathComponent("tail_16k.wav")
        _ = try RecordingTail.copy(last: seconds, of: recording, to: tail)
        try await AudioConverter.convertTo16kHzMonoWAV(input: tail, output: converted)
        _ = file
        return try AudioGate.loadSamples(from: converted)
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// Upward zero crossings a second, past the resampler's first milliseconds.
    private func pitch(_ samples: [Float]) -> Double {
        let steady = Array(samples.dropFirst(800))
        let crossings = zip(steady, steady.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) / (Double(steady.count) / 16000)
    }

    func testTheTapSinkHearsTheCallAtItsPitchAndLength() throws {
        let heard = heardOnTheTap(try buffers(seconds: 3, left: 0.5, right: 0.5))

        // A stereo frame read as two mono ones would last twice as long an octave down.
        XCTAssertEqual(Double(heard.count), 48000, accuracy: 300)
        XCTAssertEqual(pitch(heard), 440, accuracy: 2)
        XCTAssertEqual(rms(heard), 0.354, accuracy: 0.01)
    }

    func testTheTailOfTheOpenFileIsTheCallAtItsPitchAndLength() async throws {
        // 1.37 s: the tail starts in the middle of a tap buffer.
        let heard = try await heardInTheFile(try buffers(seconds: 3, left: 0.5, right: 0.5), last: 1.37)

        // The file converter keeps back its last 26 ms (416 samples of 21 920).
        XCTAssertEqual(Double(heard.count), 1.37 * 16000, accuracy: 600)
        XCTAssertEqual(pitch(heard), 440, accuracy: 2)
        // Lifted to the recognition peak of 0.7, less the ringing where the
        // tail cuts into the tone.
        XCTAssertEqual(rms(heard), 0.495, accuracy: 0.05)
    }

    /// The system converter remaps two channels to one by keeping the left: a
    /// voice in the right channel alone reached neither live text nor the
    /// final transcript.
    func testAVoiceInTheRightChannelAloneIsHeardOnTheTap() throws {
        let heard = heardOnTheTap(try buffers(seconds: 1, left: 0, right: 0.5))

        XCTAssertEqual(pitch(heard), 440, accuracy: 4)
        XCTAssertGreaterThan(rms(heard), 0.15)
    }

    func testAVoiceInTheRightChannelAloneIsHeardInTheFile() async throws {
        let heard = try await heardInTheFile(try buffers(seconds: 2, left: 0, right: 0.5), last: 1)

        XCTAssertEqual(pitch(heard), 440, accuracy: 4)
        XCTAssertGreaterThan(rms(heard), 0.15)
    }

    func testAVoiceInTheLeftChannelAloneIsStillHeard() async throws {
        let sound = try buffers(seconds: 2, left: 0.5, right: 0)

        XCTAssertGreaterThan(rms(heardOnTheTap(sound)), 0.15)
        let inTheFile = try await heardInTheFile(sound, last: 1)
        XCTAssertGreaterThan(rms(inTheFile), 0.15)
    }
}
