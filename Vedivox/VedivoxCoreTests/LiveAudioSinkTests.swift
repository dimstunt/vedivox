import AVFoundation
import os
import XCTest

/// The second consumer of a capture tap (live-transcript D3): whatever format
/// the tap hands over, the recogniser gets 16 kHz mono with the sound in it.
final class LiveAudioSinkTests: XCTestCase {

    /// 0.1 s at 48 kHz, a 440 Hz tone in the listed channels, silence elsewhere.
    private func buffer(channels: AVAudioChannelCount, toneIn sounding: Set<Int>) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AudioConverter.float32Format(channels: channels, sampleRate: 48000))
        let frames = 4800
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0 ..< Int(channels) {
            for frame in 0 ..< frames {
                data[channel][frame] = sounding.contains(channel)
                    ? 0.5 * sinf(2 * .pi * 440 * Float(frame) / 48000) : 0
            }
        }
        return buffer
    }

    private func delivered(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let collected = OSAllocatedUnfairLock(initialState: [Float]())
        let sink = LiveAudioSink(onSamples: { samples in collected.withLock { $0.append(contentsOf: samples) } })
        sink.feed(buffer)
        return collected.withLock { $0 }
    }

    /// The resampler holds back ~15 ms of its first buffer (1360 of 1600
    /// samples come out); later buffers make up for it.
    private static let priming = 300.0

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    func testMonoIsResampledTo16k() throws {
        let samples = delivered(try buffer(channels: 1, toneIn: [0]))
        XCTAssertEqual(Double(samples.count), 1600, accuracy: Self.priming)
        XCTAssertGreaterThan(rms(samples), 0.2)
    }

    func testStereoKeepsItsSound() throws {
        let samples = delivered(try buffer(channels: 2, toneIn: [0, 1]))
        XCTAssertEqual(Double(samples.count), 1600, accuracy: Self.priming)
        XCTAssertGreaterThan(rms(samples), 0.2)
    }

    /// The system converter writes digital zeros for 3 → 1; the live draft of
    /// a dictation on such a microphone used to be silent.
    func testThreeChannelsWithSpeechInOneAreNotSilent() throws {
        let samples = delivered(try buffer(channels: 3, toneIn: [1]))
        XCTAssertEqual(Double(samples.count), 1600, accuracy: Self.priming)
        XCTAssertGreaterThan(rms(samples), 0.2)
    }

    func testFeedDurationIsReportedForEveryBuffer() throws {
        let durations = OSAllocatedUnfairLock(initialState: [Double]())
        let sink = LiveAudioSink(
            onSamples: { _ in },
            onFeedDuration: { seconds in durations.withLock { $0.append(seconds) } }
        )
        let input = try buffer(channels: 1, toneIn: [0])
        sink.feed(input)
        sink.feed(input)

        let seen = durations.withLock { $0 }
        XCTAssertEqual(seen.count, 2)
        XCTAssertTrue(seen.allSatisfy { $0 >= 0 && $0 < 1 })
    }
}
