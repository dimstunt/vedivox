import XCTest

/// The mic-track timeline pieces that need no hardware: stall
/// detection by the age of the last real frame, watchdog pacing, the tail
/// owed at stop, and one rebuild per burst of configuration changes.
final class MicStallTests: XCTestCase {

    func testStallNeedsAnOldFrameAndAnOldStart() {
        // (а) frame 0.3 s ago → alive
        XCTAssertFalse(MicrophoneCapture.isStalled(now: 100, lastFrame: 99.7, lastRebuild: 0, captureStart: 50))
        // (б) frame 2 s ago, but rebuilt 0.4 s ago → still starting
        XCTAssertFalse(MicrophoneCapture.isStalled(now: 100, lastFrame: 98, lastRebuild: 99.6, captureStart: 50))
        // (в) no frame yet, started 1.2 s ago → slow input open, not a death
        XCTAssertFalse(MicrophoneCapture.isStalled(now: 100, lastFrame: 0, lastRebuild: 0, captureStart: 98.8))
        // (г) no frame yet, started 2.5 s ago → stalled
        XCTAssertTrue(MicrophoneCapture.isStalled(now: 100, lastFrame: 0, lastRebuild: 0, captureStart: 97.5))
        // (д) frame 1.1 s ago, started 5 s ago → stalled
        XCTAssertTrue(MicrophoneCapture.isStalled(now: 100, lastFrame: 98.9, lastRebuild: 0, captureStart: 95))
        // (е) nothing ever happened → not recording, not stalled
        XCTAssertFalse(MicrophoneCapture.isStalled(now: 100, lastFrame: 0, lastRebuild: 0, captureStart: 0))
    }

    // (ж) Three stalls double the pace three times; the grace period after a
    // rebuild does not reset it — only a real frame does.
    func testWatchdogBackoffResetsOnlyOnRealFrames() {
        let base = MicrophoneCapture.watchdogInterval
        var interval = base
        for _ in 0 ..< 3 {
            interval = MicrophoneCapture.nextWatchdogInterval(current: interval, stalled: true, framesAdvanced: false)
        }
        XCTAssertEqual(interval, base * 8)

        interval = MicrophoneCapture.nextWatchdogInterval(current: interval, stalled: false, framesAdvanced: false)
        XCTAssertEqual(interval, base * 8, "not stalled only because of the start grace — pace unchanged")

        interval = MicrophoneCapture.nextWatchdogInterval(current: interval, stalled: false, framesAdvanced: true)
        XCTAssertEqual(interval, base)
    }

    func testTailOwedAtStop() {
        // no frames ever, stop 5 s after start
        XCTAssertEqual(MicrophoneCapture.tailFrames(now: 105, lastBufferEnd: 0, captureStart: 100, sampleRate: 48_000), 240_000)
        // last buffer ended at 10 s, stop at 12 s
        XCTAssertEqual(MicrophoneCapture.tailFrames(now: 112, lastBufferEnd: 110, captureStart: 100, sampleRate: 48_000), 96_000)
        // stop 0.1 s after the last buffer: normal latency, nothing owed
        XCTAssertEqual(MicrophoneCapture.tailFrames(now: 110.1, lastBufferEnd: 110, captureStart: 100, sampleRate: 48_000), 0)
        // never started
        XCTAssertEqual(MicrophoneCapture.tailFrames(now: 5, lastBufferEnd: 0, captureStart: 0, sampleRate: 48_000), 0)
    }

    // (и) The first buffer after `start` is placed from the anchor with no
    // threshold; after a rebuild the 0.25 s threshold hides restart latency.
    func testFirstBufferAfterStartIsFilledFromTheAnchor() throws {
        let anchor = MicrophoneCapture.hostTicks(fromSeconds: 100)
        let at = MicrophoneCapture.hostTicks(fromSeconds: 100.1)

        let started = TapState()
        started.setCaptureStart(anchor)
        started.expectFirstFrame(after: "start")
        let afterStart = try XCTUnwrap(started.silenceOwed(beforeBufferAt: at, sampleRate: 48_000))
        XCTAssertEqual(Double(afterStart.frames), 4_800, accuracy: 1, "0.1 s from the anchor, threshold 0")

        let rebuilt = TapState()
        rebuilt.setCaptureStart(anchor)
        rebuilt.expectFirstFrame(after: "rebuild")
        let afterRebuild = try XCTUnwrap(rebuilt.silenceOwed(beforeBufferAt: at, sampleRate: 48_000))
        XCTAssertEqual(afterRebuild.frames, 0, "0.1 s after a rebuild is normal latency")
    }

    func testDebouncerRebuildsOncePerBurst() {
        var debouncer = ConfigChangeDebouncer(quietWindow: 0.1)

        // A burst of five within 40 ms: nothing until the window is quiet.
        for k in 0 ..< 5 { debouncer.note(at: 10 + Double(k) * 0.01) }
        XCTAssertFalse(debouncer.shouldRebuild(at: 10.10))
        XCTAssertEqual(try XCTUnwrap(debouncer.waitUntilQuiet(at: 10.10)), 0.04, accuracy: 1e-9)
        XCTAssertTrue(debouncer.shouldRebuild(at: 10.15), "100 ms after the last notification")
        XCTAssertFalse(debouncer.shouldRebuild(at: 10.30), "consumed — one rebuild per burst")
        XCTAssertNil(debouncer.waitUntilQuiet(at: 10.30))

        // A single notification: the same 100 ms.
        debouncer.note(at: 20)
        XCTAssertFalse(debouncer.shouldRebuild(at: 20.05))
        XCTAssertTrue(debouncer.shouldRebuild(at: 20.11))
    }
}
