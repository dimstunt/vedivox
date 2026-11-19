import AVFoundation
import os
import XCTest

/// What the microphone tap of a recording is given to feed. The tap has one
/// slot for a second consumer and a meeting has two: the live transcript and
/// the speech clock of the after-the-meeting reminders. Build 1375 installed
/// the clock over the live transcript's sink, and a real recording gave no
/// live text from the microphone at all («tap 0 calls»).
final class AudioSessionLiveSinkTests: XCTestCase {

    /// A second of a 440 Hz tone at 48 kHz mono, in tap-sized buffers.
    private func speak(into sink: LiveAudioSink) throws {
        let format = try XCTUnwrap(AudioConverter.float32Format(channels: 1, sampleRate: 48000))
        for _ in 0 ..< 10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            let data = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0 ..< 4800 { data[0][frame] = 0.5 * sinf(2 * .pi * 440 * Float(frame) / 48000) }
            sink.feed(buffer)
        }
    }

    func testTheTapFeedsTheLiveTranscriptAndTheSpeechClockTogether() async throws {
        let heard = OSAllocatedUnfairLock(initialState: 0)
        let session = AudioSessionManager()
        await session.setLiveSinks(
            mic: LiveAudioSink(onSamples: { samples in heard.withLock { $0 += samples.count } }),
            system: nil
        )

        try speak(into: await session.micTapSink())

        XCTAssertGreaterThan(heard.withLock { $0 }, 12000, "the live transcript gets the microphone")
        XCTAssertNotNil(session.lastMicSpeechAt, "and the reminders still hear speech")
    }

    func testTheCostOfTheTapIsStillReportedToTheLiveTranscript() async throws {
        let timed = OSAllocatedUnfairLock(initialState: 0)
        let session = AudioSessionManager()
        await session.setLiveSinks(
            mic: LiveAudioSink(onSamples: { _ in }, onFeedDuration: { _ in timed.withLock { $0 += 1 } }),
            system: nil
        )

        try speak(into: await session.micTapSink())

        XCTAssertEqual(timed.withLock { $0 }, 10, "one timing per tap buffer: the load summary counts them")
    }

    func testWithoutALiveTranscriptTheTapKeepsTheSpeechClock() async throws {
        let session = AudioSessionManager()
        try speak(into: await session.micTapSink())
        XCTAssertNotNil(session.lastMicSpeechAt)
    }

    func testADetachedLiveTranscriptIsNotFedByTheNextRecording() async throws {
        let heard = OSAllocatedUnfairLock(initialState: 0)
        let session = AudioSessionManager()
        await session.setLiveSinks(
            mic: LiveAudioSink(onSamples: { samples in heard.withLock { $0 += samples.count } }),
            system: nil
        )
        await session.setLiveSinks(mic: nil, system: nil)

        try speak(into: await session.micTapSink())

        XCTAssertEqual(heard.withLock { $0 }, 0)
    }
}
