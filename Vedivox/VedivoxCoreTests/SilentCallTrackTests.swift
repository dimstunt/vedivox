import AVFoundation
import XCTest

/// The recording-time warning for a call track that records nothing.
final class SilentCallTrackTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func run(_ check: inout SilentCallTrack, seconds: Int, heard: Bool = false, output: Bool) {
        for second in stride(from: 0, through: seconds, by: 5) {
            check.tick(heard: heard, callOutputting: output, now: start.addingTimeInterval(TimeInterval(second)))
        }
    }

    /// A call plays for a minute and the track is zero: the warning goes up.
    func testCallPlayingIntoZerosWarns() {
        var check = SilentCallTrack()
        run(&check, seconds: 55, output: true)
        XCTAssertFalse(check.warning, "under the threshold")
        check.tick(heard: false, callOutputting: true, now: start.addingTimeInterval(60))
        XCTAssertTrue(check.warning)
    }

    /// Ordinary silence — a memo, a pause, nothing playing — never warns.
    func testSilenceWithoutCallOutputDoesNotWarn() {
        var check = SilentCallTrack()
        run(&check, seconds: 600, output: false)
        XCTAssertFalse(check.warning)
        XCTAssertEqual(check.callOutputSeconds, 0)
    }

    /// One non-zero sample proves the grant: the warning clears and never returns.
    func testFirstSoundClearsForGood() {
        var check = SilentCallTrack()
        run(&check, seconds: 120, output: true)
        XCTAssertTrue(check.warning)
        check.tick(heard: true, callOutputting: true, now: start.addingTimeInterval(125))
        XCTAssertFalse(check.warning)
        check.tick(heard: false, callOutputting: true, now: start.addingTimeInterval(400))
        XCTAssertFalse(check.warning)
    }

    /// A long gap between ticks counts as `maxStep`, not as minutes of a call.
    func testStalledTicksDoNotCountMinutes() {
        var check = SilentCallTrack()
        check.tick(heard: false, callOutputting: true, now: start)
        check.tick(heard: false, callOutputting: true, now: start.addingTimeInterval(300))
        XCTAssertEqual(check.callOutputSeconds, SilentCallTrack.maxStep)
        XCTAssertFalse(check.warning)
    }

    /// Digital zero is no sound; any sample off zero, however quiet, is.
    func testHasSound() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<1024 { samples[index] = 0 }
        XCTAssertFalse(SystemAudioCapture.hasSound(buffer.audioBufferList))
        samples[1023] = 1e-7
        XCTAssertTrue(SystemAudioCapture.hasSound(buffer.audioBufferList))
    }
}
