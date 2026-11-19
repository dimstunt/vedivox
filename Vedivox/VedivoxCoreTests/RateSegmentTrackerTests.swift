import XCTest

final class RateSegmentTrackerTests: XCTestCase {

    /// Feed callbacks simulating a device delivering `frames` frames per callback
    /// at `effectiveRate` frames per wall second, starting at `startNanos`/`startFrame`.
    /// Returns (lastNanos, lastFrame, committed segments seen from addCallback).
    @discardableResult
    private func feed(
        _ tracker: inout RateSegmentTracker,
        seconds: Double,
        effectiveRate: Double,
        framesPerCallback: Int64 = 512,
        startNanos: UInt64,
        startFrame: Int64
    ) -> (nanos: UInt64, frame: Int64, committed: [RateSegment]) {
        var nanos = startNanos
        var frame = startFrame
        var committed: [RateSegment] = []
        let callbackNanos = UInt64(Double(framesPerCallback) / effectiveRate * 1_000_000_000)
        let total = Int64(seconds * effectiveRate)
        var delivered: Int64 = 0
        while delivered < total {
            nanos += callbackNanos
            frame += framesPerCallback
            delivered += framesPerCallback
            if let seg = tracker.addCallback(hostNanos: nanos, framePosition: frame) {
                committed.append(seg)
            }
        }
        return (nanos, frame, committed)
    }

    func testSteadyRateProducesSingleSegment() {
        var tracker = RateSegmentTracker(headerRate: 48000)
        let result = feed(&tracker, seconds: 10, effectiveRate: 48000, startNanos: 1_000_000, startFrame: 0)

        XCTAssertTrue(result.committed.isEmpty, "No rate change should be committed on a steady stream")
        XCTAssertEqual(tracker.segments.count, 1)
        XCTAssertEqual(tracker.segments[0].startFrame, 0)
        XCTAssertEqual(tracker.segments[0].rate, 48000, accuracy: 1)
        XCTAssertFalse(tracker.hasRateChange)
    }

    func testHalvedRateCommitsSegmentNearBoundary() {
        var tracker = RateSegmentTracker(headerRate: 48000)
        let phase1 = feed(&tracker, seconds: 5, effectiveRate: 48000, startNanos: 1_000_000, startFrame: 0)
        XCTAssertTrue(phase1.committed.isEmpty)

        let phase2 = feed(
            &tracker, seconds: 5, effectiveRate: 24000,
            startNanos: phase1.nanos, startFrame: phase1.frame
        )

        XCTAssertEqual(phase2.committed.count, 1, "Exactly one rate change should be committed")
        XCTAssertEqual(tracker.segments.count, 2)
        let seg = tracker.segments[1]
        XCTAssertEqual(seg.rate, 24000, accuracy: 24000 * 0.03)
        // Boundary detected within ~3 measurement windows of the true change point.
        let trueBoundary = phase1.frame
        XCTAssertEqual(Double(seg.startFrame), Double(trueBoundary), accuracy: 3.5 * 48000)
        XCTAssertTrue(tracker.hasRateChange)
    }

    func test44100ShiftIsDetected() {
        var tracker = RateSegmentTracker(headerRate: 48000)
        let phase1 = feed(&tracker, seconds: 5, effectiveRate: 48000, startNanos: 1_000_000, startFrame: 0)
        let phase2 = feed(
            &tracker, seconds: 6, effectiveRate: 44100,
            startNanos: phase1.nanos, startFrame: phase1.frame
        )

        XCTAssertEqual(phase2.committed.count, 1, "48000→44100 (8.1% deviation) must be detected")
        XCTAssertEqual(tracker.segments[1].rate, 44100, accuracy: 44100 * 0.03)
    }

    func testReturnToOriginalRateProducesThreeSegments() {
        var tracker = RateSegmentTracker(headerRate: 48000)
        let p1 = feed(&tracker, seconds: 5, effectiveRate: 48000, startNanos: 1_000_000, startFrame: 0)
        let p2 = feed(&tracker, seconds: 8, effectiveRate: 24000, startNanos: p1.nanos, startFrame: p1.frame)
        let p3 = feed(&tracker, seconds: 8, effectiveRate: 48000, startNanos: p2.nanos, startFrame: p2.frame)

        XCTAssertEqual(p2.committed.count, 1)
        XCTAssertEqual(p3.committed.count, 1)
        XCTAssertEqual(tracker.segments.count, 3)
        XCTAssertEqual(tracker.segments[1].rate, 24000, accuracy: 24000 * 0.03)
        XCTAssertEqual(tracker.segments[2].rate, 48000, accuracy: 48000 * 0.03)
    }

    func testSingleAnomalousWindowIsIgnored() {
        var tracker = RateSegmentTracker(headerRate: 48000)
        let p1 = feed(&tracker, seconds: 5, effectiveRate: 48000, startNanos: 1_000_000, startFrame: 0)

        // One burst: +96000 frames delivered in 0.1s of wall time (e.g. a scheduling
        // hiccup dumping queued buffers) — a single deviating window must not commit.
        let nanos = p1.nanos + 100_000_000
        let frame = p1.frame + 96_000
        XCTAssertNil(tracker.addCallback(hostNanos: nanos, framePosition: frame))

        // Back to steady 48k afterwards.
        let p2 = feed(&tracker, seconds: 5, effectiveRate: 48000, startNanos: nanos, startFrame: frame)
        XCTAssertTrue(p2.committed.isEmpty, "Isolated timing spike must not create a segment")
        XCTAssertEqual(tracker.segments.count, 1)
    }

    func testDiscontinuityResetsWindow() {
        var tracker = RateSegmentTracker(headerRate: 48000)
        let p1 = feed(&tracker, seconds: 3, effectiveRate: 48000, startNanos: 1_000_000, startFrame: 0)

        // Gap fill: 5 seconds of silence written instantly (no wall time passes).
        let frameAfterFill = p1.frame + 240_000
        tracker.noteDiscontinuity(framePosition: frameAfterFill)

        let p2 = feed(&tracker, seconds: 5, effectiveRate: 48000, startNanos: p1.nanos, startFrame: frameAfterFill)
        XCTAssertTrue(p2.committed.isEmpty, "Silence fill flagged via noteDiscontinuity must not trigger a rate change")
        XCTAssertEqual(tracker.segments.count, 1)
    }
}
