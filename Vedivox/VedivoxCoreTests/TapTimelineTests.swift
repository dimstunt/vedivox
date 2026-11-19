import XCTest

/// The system-audio tap timeline: the leading silence goes in once
/// even though the stream starts at a negative sample time, mid-stream gaps
/// stay wall-clock bounded, a fresh stream is a backward jump that
/// is filled, and the file is padded to the stop.
final class TapTimelineTests: XCTestCase {
    private let sr = 48_000.0
    private let start: UInt64 = 1_000_000_000_000

    private func ns(_ seconds: Double) -> UInt64 { UInt64(seconds * 1_000_000_000) }

    // (а) one meeting: first callback at −911 twelve seconds in, the next 27 ms later at 405.
    func testNegativeStartCounterPrependsOnce() {
        var timeline = TapTimeline(sampleRate: sr, captureStartHostNanos: start)

        let first = timeline.advance(sampleTime: -911, hostNanos: start + ns(12), frames: 512)
        XCTAssertEqual(first, .first(silenceFrames: 576_000))

        let second = timeline.advance(sampleTime: 405, hostNanos: start + ns(12.027), frames: 512)
        XCTAssertEqual(second, .gap(fill: 804, counted: 804), "the counter, not the capture start, decides the second callback")
        // 576_000 + 804 = 12.017 s of silence, not 24.1 s.
    }

    // (б) IOProc idle for 5 s, counter and clock agree.
    func testIdleGapIsFilledByTheCounter() {
        var timeline = TapTimeline(sampleRate: sr, captureStartHostNanos: start)
        _ = timeline.advance(sampleTime: 0, hostNanos: start, frames: 512)

        let event = timeline.advance(sampleTime: 512 + 240_000, hostNanos: start + ns(5), frames: 512)
        XCTAssertEqual(event, .gap(fill: 240_000, counted: 240_000))
    }

    // (в) Counter jumps 20 minutes while the clock says one second.
    func testCounterDiscontinuityIsBoundedByTheClock() {
        var timeline = TapTimeline(sampleRate: sr, captureStartHostNanos: start)
        _ = timeline.advance(sampleTime: 0, hostNanos: start, frames: 512)

        let event = timeline.advance(sampleTime: 512 + 57_600_000, hostNanos: start + ns(1), frames: 512)
        XCTAssertEqual(event, .gap(fill: 48_000, counted: 57_600_000))
    }

    // (г) Callback stamped before the capture start: nothing owed.
    func testCallbackBeforeCaptureStartPrependsNothing() {
        var timeline = TapTimeline(sampleRate: sr, captureStartHostNanos: start)
        XCTAssertEqual(timeline.advance(sampleTime: -911, hostNanos: start - ns(0.2), frames: 512), .first(silenceFrames: 0))
    }

    // (д) A fresh stream restarts near −900: the idle time between streams is the clock's.
    func testBackwardJumpIsFilledByTheClock() {
        var timeline = TapTimeline(sampleRate: sr, captureStartHostNanos: start)
        _ = timeline.advance(sampleTime: 100_000, hostNanos: start, frames: 512)

        let event = timeline.advance(sampleTime: -900, hostNanos: start + ns(3), frames: 512)
        XCTAssertEqual(event, .backward(frames: 101_412, fill: 144_000))
    }

    // (е) The tail: a stream that never started, and one that stopped before the recording.
    func testFinishPadsToTheStop() {
        let silent = TapTimeline(sampleRate: sr, captureStartHostNanos: start)
        XCTAssertEqual(silent.finish(nowHostNanos: start + ns(60)), 2_880_000)

        var timeline = TapTimeline(sampleRate: sr, captureStartHostNanos: start)
        _ = timeline.advance(sampleTime: 0, hostNanos: start + ns(10), frames: 512)
        XCTAssertEqual(timeline.finish(nowHostNanos: start + ns(12)), 96_000 - 512, "measured from the end of the last buffer")
    }

    // (ж) The dangerous sequence end to end: one .first, one .backward, nothing else inserts silence.
    func testRestartedStreamPrependsOnceAndFillsOnce() {
        var timeline = TapTimeline(sampleRate: sr, captureStartHostNanos: start)
        var events: [TapTimeline.Event] = []
        var sampleTime = -911.0
        var host = start + ns(12)
        events.append(timeline.advance(sampleTime: sampleTime, hostNanos: host, frames: 512))
        for _ in 0 ..< 200 {
            sampleTime += 512
            host += ns(512 / sr)
            events.append(timeline.advance(sampleTime: sampleTime, hostNanos: host, frames: 512))
        }
        events.append(timeline.advance(sampleTime: -900, hostNanos: host + ns(3), frames: 512))

        let firsts = events.filter { if case .first = $0 { return true } else { return false } }
        let backwards = events.filter { if case .backward = $0 { return true } else { return false } }
        let gaps = events.filter { if case .gap = $0 { return true } else { return false } }
        XCTAssertEqual(firsts, [.first(silenceFrames: 576_000)])
        XCTAssertEqual(backwards.count, 1)
        if case .backward(_, let fill) = backwards[0] { XCTAssertEqual(fill, 144_000) }
        XCTAssertTrue(gaps.isEmpty, "a contiguous stream inserts nothing: \(gaps)")
    }
}
