import AVFoundation
import XCTest

/// A damaged file used to pass `vedivox import` with exit 0 and fail later in the
/// background — a shell loop over a folder never noticed (scriptable-cli 8.3).
final class ImportAudioCheckTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportAudioCheckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRealAudioHasTrack() async throws {
        let url = tempDir.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)

        let hasTrack = await AudioConverter.hasAudioTrack(url)
        XCTAssertTrue(hasTrack)
    }

    func testRandomBytesHaveNoTrack() async throws {
        let url = tempDir.appendingPathComponent("broken.m4a")
        try Data((0..<50_000).map { _ in UInt8.random(in: 0...255) }).write(to: url)

        let hasTrack = await AudioConverter.hasAudioTrack(url)
        XCTAssertFalse(hasTrack)
    }
}
