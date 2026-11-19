import XCTest

/// The system-capture watchdog without Core Audio: stall detection by the
/// age of the last callback, backoff while rebuilds keep failing, and the
/// track length across a rebuild (the fresh stream restarts near −900).
final class SystemCaptureWatchdogTests: XCTestCase {

    func testStalledOnlyAfterTwoSecondsWithoutCallbacks() {
        // callbacks flow: last one 0.01 s ago
        XCTAssertFalse(SystemCaptureWatchdog.isStalled(now: 100, lastCallback: 99.99, lastStart: 50))
        // stopped 1.9 s ago → not yet
        XCTAssertFalse(SystemCaptureWatchdog.isStalled(now: 100, lastCallback: 98.1, lastStart: 50))
        // stopped 2.1 s ago → dead
        XCTAssertTrue(SystemCaptureWatchdog.isStalled(now: 100, lastCallback: 97.9, lastStart: 50))
        // right after a rebuild: old callbacks 5 s ago, restarted 0.2 s ago → starting
        XCTAssertFalse(SystemCaptureWatchdog.isStalled(now: 100, lastCallback: 95, lastStart: 99.8))
        // no callback ever, started 2.5 s ago → dead (the eager start delivers within 0.1 s)
        XCTAssertTrue(SystemCaptureWatchdog.isStalled(now: 100, lastCallback: 0, lastStart: 97.5))
        // nothing ever happened → not capturing
        XCTAssertFalse(SystemCaptureWatchdog.isStalled(now: 100, lastCallback: 0, lastStart: 0))
    }

    // Three stalls double the pace three times; the grace after a rebuild
    // keeps it; only advancing callbacks bring it back to base.
    func testBackoffResetsOnlyOnRealCallbacks() {
        var watchdog = SystemCaptureWatchdog()
        let base = SystemCaptureWatchdog.interval

        XCTAssertNil(watchdog.tick(now: 10, lastCallback: 9.99, lastStart: 5, callbacks: 500))
        XCTAssertEqual(watchdog.currentInterval, base)

        var now = 12.5
        for _ in 0 ..< 3 {
            XCTAssertNotNil(watchdog.tick(now: now, lastCallback: 10, lastStart: 5, callbacks: 500))
            now += 3
        }
        XCTAssertEqual(watchdog.currentInterval, base * 8)

        // rebuilt 0.3 s ago, still no callbacks: grace, pace unchanged
        XCTAssertNil(watchdog.tick(now: now, lastCallback: 10, lastStart: now - 0.3, callbacks: 500))
        XCTAssertEqual(watchdog.currentInterval, base * 8)

        // callbacks flow again
        XCTAssertNil(watchdog.tick(now: now + 1, lastCallback: now + 0.99, lastStart: now - 0.3, callbacks: 600))
        XCTAssertEqual(watchdog.currentInterval, base)
    }

    // The stream died 0.2 s in (counter 10_000), the rebuild came 3 s later
    // and the fresh stream starts at −900: exactly 3 s of silence, once —
    // even though the counter jump is too small for the backward heuristic.
    func testRebuiltStreamFillsExactlyTheIdleTime() {
        let sr = 48_000.0
        let start: UInt64 = 1_000_000_000_000
        var timeline = TapTimeline(sampleRate: sr, captureStartHostNanos: start)
        _ = timeline.advance(sampleTime: -911, hostNanos: start + 60_000_000, frames: 512)
        _ = timeline.advance(sampleTime: 10_000, hostNanos: start + 290_000_000, frames: 512)

        timeline.expectRestart()
        let event = timeline.advance(sampleTime: -900, hostNanos: start + 3_290_000_000, frames: 512)
        XCTAssertEqual(event, .backward(frames: 11_412, fill: 144_000))

        // the flag is consumed: the next callback is contiguous
        XCTAssertEqual(timeline.advance(sampleTime: -388, hostNanos: start + 3_300_666_667, frames: 512), .contiguous)
    }

    // Rebuilt before the first stream delivered anything: the fresh stream's
    // first callback pads from the anchor, and the flag does not leak into
    // the callback after it.
    func testRebuildBeforeAnyCallbackPadsFromTheAnchorOnce() {
        let sr = 48_000.0
        let start: UInt64 = 1_000_000_000_000
        var timeline = TapTimeline(sampleRate: sr, captureStartHostNanos: start)
        timeline.expectRestart()
        XCTAssertEqual(timeline.advance(sampleTime: -900, hostNanos: start + 2_500_000_000, frames: 512), .first(silenceFrames: 120_000))
        XCTAssertEqual(timeline.advance(sampleTime: -388, hostNanos: start + 2_510_666_667, frames: 512), .contiguous)
    }
}
