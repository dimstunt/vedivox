import AVFoundation
import XCTest

/// The player must not hold the output device while nothing is audible.
///
/// Before this test existed the engine started the moment a meeting was
/// opened — including the one being recorded, which is auto-selected — and
/// `pause()` only paused the player nodes. Vedivox therefore kept an output IO
/// running in coreaudiod for as long as any meeting was open.
@MainActor
final class AudioPlaybackEngineLifecycleTests: XCTestCase {

    /// The engine plays for real; a Mac mini or CI runner without an output
    /// device has nothing to start, so the assertions there would only test that.
    override func setUp() async throws {
        try XCTSkipIf(AudioObjectID.readDefaultOutputDevice() == nil, "no audio output device")
    }

    /// Two seconds of silence: inaudible, so the test can really play it.
    private func writeSilentWAV(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("silence.wav")
        let rate = 16_000.0
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
        let frames = AVAudioFrameCount(rate * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    /// `load()` opens the file off the main actor; wait for it to land.
    private func waitForLoad(_ playback: AudioPlaybackService) async {
        let deadline = Date().addingTimeInterval(5)
        while playback.duration == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testEngineRunsOnlyWhilePlaying() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackLifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let playback = AudioPlaybackService()
        playback.load(micURL: try writeSilentWAV(in: tempDir))
        await waitForLoad(playback)
        XCTAssertGreaterThan(playback.duration, 0, "load never finished")

        XCTAssertFalse(playback.isEngineRunning, "opening a meeting must not touch the output device")

        playback.play()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertTrue(playback.isEngineRunning, "play() is what starts the hardware")
        try await Task.sleep(for: .milliseconds(300))

        playback.pause()
        XCTAssertFalse(playback.isEngineRunning, "pause must release the device, not just the player nodes")
        let pausedAt = playback.currentTime
        XCTAssertGreaterThan(pausedAt, 0, "position survives pause")

        playback.play()
        XCTAssertTrue(playback.isEngineRunning, "resume starts the hardware again")
        try await Task.sleep(for: .milliseconds(200))
        playback.pause()
        XCTAssertGreaterThanOrEqual(playback.currentTime, pausedAt, "resume continues from the paused position")

        playback.stop()
        XCTAssertFalse(playback.isEngineRunning)
    }

    func testConfigurationChangeRestartsOnlyWhilePlaying() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackConfigChange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let playback = AudioPlaybackService()
        playback.load(micURL: try writeSilentWAV(in: tempDir))
        await waitForLoad(playback)
        XCTAssertGreaterThan(playback.duration, 0, "load never finished")

        playback.play()
        playback.handleConfigurationChange()
        XCTAssertTrue(playback.isEngineRunning, "a device change while playing must restart the engine")
        XCTAssertTrue(playback.isPlaying)

        playback.pause()
        playback.handleConfigurationChange()
        XCTAssertFalse(playback.isEngineRunning, "a device change on pause must not grab the output")
        XCTAssertFalse(playback.isPlaying)
        playback.stop()
    }

    func testSeekAndPlayDuringLoadApplyOnceLoaded() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackPendingSeek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let playback = AudioPlaybackService()
        playback.load(micURL: try writeSilentWAV(in: tempDir))
        // A deep link to another meeting: seek and play right after load().
        playback.seek(to: 1.0)
        playback.play()
        await waitForLoad(playback)

        XCTAssertTrue(playback.isPlaying, "play during load must start playback once loaded")
        XCTAssertGreaterThanOrEqual(playback.currentTime, 1.0, "seek during load must survive the load")
        playback.stop()
    }
}
