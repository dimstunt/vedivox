import AVFoundation
import XCTest

/// The file side of a mid-recording device switch, with no engine and no
/// device: the tap body is fed synthetic buffers the way three
/// inputs in a row would deliver them. One track, in the file's format, as
/// long as the clock says, silent exactly where no input was delivering.
final class MicSwitchTrackTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicSwitchTrackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func ticks(_ seconds: Double) -> UInt64 {
        MicrophoneCapture.hostTicks(fromSeconds: seconds)
    }

    private static func format(_ rate: Double, _ channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
    }

    /// `seconds` of a 440 Hz tone in 0.1 s buffers, the first one stamped `start`.
    private static func feed(
        _ tap: AVAudioNodeTapBlock, seconds: Int, format: AVAudioFormat, startingAt start: Double
    ) throws {
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        for k in 0 ..< seconds * 10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0 ..< Int(format.channelCount) {
                let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
                for i in 0 ..< Int(frames) {
                    let n = Double(k * Int(frames) + i)
                    samples[i] = Float(0.5 * sin(2 * .pi * 440 * n / format.sampleRate))
                }
            }
            tap(buffer, AVAudioTime(hostTime: ticks(start + Double(k) * 0.1)))
        }
    }

    /// Three inputs in a row write one track. The file and the taps holding
    /// it live only in here: the header is final once this returns.
    private func recordAcrossTwoSwitches(to url: URL) throws -> TapState {
        let fileFormat = try Self.format(48_000, 1)
        // Opened the way MicrophoneCapture opens the track.
        let track = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: fileFormat.sampleRate,
                AVNumberOfChannelsKey: fileFormat.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let state = TapState()
        let anchor = 1_000.0
        state.setCaptureStart(Self.ticks(anchor))

        // 1 s from a 48 kHz mono mic, from the anchor on.
        state.expectFirstFrame(after: "start")
        state.willStart(input: "Desk USB Mic")
        var tap = try MicrophoneCapture.tapBlock(from: fileFormat, to: fileFormat, outputFile: track, state: state)
        try Self.feed(tap, seconds: 1, format: fileFormat, startingAt: anchor)

        // The mic is lost; a 24 kHz headset delivers its first frame 2 s later.
        state.expectFirstFrame(after: "rebuild", why: MicSwitchPolicy.lostReason)
        state.willStart(input: "Wireless Buds")
        let headset = try Self.format(24_000, 1)
        tap = try MicrophoneCapture.tapBlock(from: headset, to: fileFormat, outputFile: track, state: state)
        try Self.feed(tap, seconds: 1, format: headset, startingAt: anchor + 3)

        // A stereo 44.1 kHz interface takes over 0.1 s after the headset's
        // last buffer: under the fill threshold, nothing is added.
        state.expectFirstFrame(after: "rebuild", why: MicSwitchPolicy.betterReason)
        state.willStart(input: "Studio Interface")
        let interface = try Self.format(44_100, 2)
        tap = try MicrophoneCapture.tapBlock(from: interface, to: fileFormat, outputFile: track, state: state)
        try Self.feed(tap, seconds: 1, format: interface, startingAt: anchor + 4.1)
        return state
    }

    func testTrackStaysOneAndAlignedAcrossTwoSwitches() throws {
        let url = tempDir.appendingPathComponent("mic.wav")
        let state = try recordAcrossTwoSwitches(to: url)
        XCTAssertEqual(state.errors, 0)

        let written = try AVAudioFile(forReading: url)
        XCTAssertEqual(written.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(written.fileFormat.channelCount, 1)
        // 1 s of mic + 2 s of silence + 1 s of headset + 1 s of interface.
        XCTAssertEqual(Double(written.length) / 48_000, 5.0, accuracy: 0.05)
        XCTAssertEqual(state.framesWritten, written.length, "every frame in the file is accounted for")

        let all = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: written.processingFormat, frameCapacity: AVAudioFrameCount(written.length)))
        try written.read(into: all)
        let samples = try XCTUnwrap(all.floatChannelData?[0])
        func slice(_ from: Double, _ to: Double) -> [Float] {
            (Int(from * 48_000) ..< Int(to * 48_000)).map { samples[$0] }
        }
        func rms(_ values: [Float]) -> Float {
            (values.reduce(0) { $0 + $1 * $1 } / Float(values.count)).squareRoot()
        }
        XCTAssertEqual(rms(slice(0.1, 0.9)), 0.354, accuracy: 0.02, "the first mic, as delivered")
        XCTAssertEqual(slice(1.05, 2.95).map(abs).max(), 0, "no input was delivering: silence")
        XCTAssertEqual(rms(slice(3.1, 3.9)), 0.354, accuracy: 0.03, "24 kHz resampled to the file's rate")
        XCTAssertEqual(rms(slice(4.1, 4.9)), 0.354, accuracy: 0.03, "44.1 kHz stereo folded and resampled")
    }

    /// An input that paused for half a second and went on by itself — no
    /// rebuild, nothing said to the tap: the file is still as long as the clock.
    func testAPauseOfTheInputKeepsTheTrackOnTheClock() throws {
        let url = tempDir.appendingPathComponent("pause.wav")
        let format = try Self.format(48_000, 1)
        let frames: Int64 = try {
            let track = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let state = TapState()
            state.setCaptureStart(Self.ticks(500))
            state.expectFirstFrame(after: "start")
            state.willStart(input: "Desk USB Mic")
            let tap = try MicrophoneCapture.tapBlock(from: format, to: format, outputFile: track, state: state)
            try Self.feed(tap, seconds: 1, format: format, startingAt: 500)
            try Self.feed(tap, seconds: 1, format: format, startingAt: 501.5)
            return state.framesWritten
        }()

        let written = try AVAudioFile(forReading: url)
        XCTAssertEqual(written.length, 120_000, accuracy: 2, "1 s + 0.5 s of silence + 1 s")
        XCTAssertEqual(frames, written.length)
        let all = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: written.processingFormat, frameCapacity: AVAudioFrameCount(written.length)))
        try written.read(into: all)
        let samples = try XCTUnwrap(all.floatChannelData?[0])
        XCTAssertEqual((Int(1.05 * 48_000) ..< Int(1.45 * 48_000)).map { abs(samples[$0]) }.max(), 0)
        XCTAssertGreaterThan((Int(1.55 * 48_000) ..< Int(2.4 * 48_000)).map { abs(samples[$0]) }.max() ?? 0, 0.4)
    }

    /// The "Mic switch" log line: from the input that was recording to the
    /// one whose frame arrives — not the ones that were tried in between.
    func testSwitchIsNamedOncePerRebuild() throws {
        let state = TapState()
        state.setCaptureStart(Self.ticks(100))
        state.expectFirstFrame(after: "start")
        state.willStart(input: "Desk USB Mic")
        let start = try XCTUnwrap(state.silenceOwed(beforeBufferAt: Self.ticks(100.1), sampleRate: 48_000))
        XCTAssertNil(start.switched, "a start is not a switch")
        state.addFrames(4_800, bufferEndHostTime: Self.ticks(100.2))

        // Lost; the first replacement would not start, the second delivers 1.5 s later.
        state.expectFirstFrame(after: "rebuild", why: MicSwitchPolicy.lostReason)
        state.willStart(input: "Wireless Buds")
        state.willStart(input: "Laptop Microphone")
        let owed = try XCTUnwrap(state.silenceOwed(beforeBufferAt: Self.ticks(101.7), sampleRate: 48_000))
        XCTAssertEqual(owed.switched, "Desk USB Mic → Laptop Microphone (current input lost)")
        XCTAssertEqual(owed.gapSeconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(Double(owed.frames), 72_000, accuracy: 1)
        state.addFrames(4_800, bufferEndHostTime: Self.ticks(101.8))
        XCTAssertNil(state.silenceOwed(beforeBufferAt: Self.ticks(101.8), sampleRate: 48_000), "once per switch")

        // The same input restarted: still one line, naming it on both sides.
        state.expectFirstFrame(after: "rebuild", why: "watchdog stall")
        state.willStart(input: "Laptop Microphone")
        let restarted = try XCTUnwrap(state.silenceOwed(beforeBufferAt: Self.ticks(103), sampleRate: 48_000))
        XCTAssertEqual(restarted.switched, "Laptop Microphone → Laptop Microphone (watchdog stall)")

        // A rebuild that failed outright, then the watchdog's retry got
        // through: the line keeps the cause of the first.
        state.expectFirstFrame(after: "rebuild", why: MicSwitchPolicy.lostReason)
        state.expectFirstFrame(after: "rebuild", why: "watchdog stall")
        state.willStart(input: "Wireless Buds")
        let retried = try XCTUnwrap(state.silenceOwed(beforeBufferAt: Self.ticks(110), sampleRate: 48_000))
        XCTAssertEqual(retried.switched, "Laptop Microphone → Wireless Buds (current input lost)")
    }

    /// The input paused and came back by itself, with no rebuild: what it
    /// skipped is silence in the track, so the clock still holds. Breaks under
    /// the fill threshold are left alone.
    func testAHoleInARunningStreamIsFilled() throws {
        let state = TapState()
        state.setCaptureStart(Self.ticks(100))
        state.expectFirstFrame(after: "start")
        state.willStart(input: "Desk USB Mic")
        _ = state.silenceOwed(beforeBufferAt: Self.ticks(100), sampleRate: 48_000)
        state.addFrames(480, bufferEndHostTime: Self.ticks(100.01))

        XCTAssertNil(state.silenceOwed(beforeBufferAt: Self.ticks(100.01), sampleRate: 48_000), "the next cycle")
        state.addFrames(480, bufferEndHostTime: Self.ticks(100.02))
        XCTAssertNil(state.silenceOwed(beforeBufferAt: Self.ticks(100.12), sampleRate: 48_000), "a 0.1 s break")
        state.addFrames(480, bufferEndHostTime: Self.ticks(100.13))

        let hole = try XCTUnwrap(state.silenceOwed(beforeBufferAt: Self.ticks(100.83), sampleRate: 48_000))
        XCTAssertEqual(Double(hole.frames), 33_600, accuracy: 1)
        XCTAssertEqual(hole.gapSeconds, 0.7, accuracy: 0.001)
        XCTAssertNil(hole.switched, "not a switch: no rebuild happened")

        // The buffer after the hole failed to write, and so did the next:
        // the hole is not paid for a second time.
        XCTAssertNil(state.silenceOwed(beforeBufferAt: Self.ticks(100.84), sampleRate: 48_000))
        XCTAssertNil(state.silenceOwed(beforeBufferAt: Self.ticks(100.85), sampleRate: 48_000))
    }
}
