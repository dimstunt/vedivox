import XCTest

/// The queue between an audio callback and the live recogniser (live-transcript
/// D4): order kept, nothing lost under the limit, and what is lost over it is
/// the oldest audio, counted to the sample.
final class LiveAudioBacklogTests: XCTestCase {

    private func ramp(_ range: Range<Int>) -> [Float] { range.map(Float.init) }

    func testKeepsOrderAndLosesNothingUnderCapacity() {
        let backlog = LiveAudioBacklog(capacity: 1000)
        for index in 0 ..< 10 {
            backlog.push(ramp(index * 50 ..< (index + 1) * 50), capturedAt: Double(index))
        }

        let block = backlog.pop(maxSamples: .max)
        XCTAssertEqual(block?.samples, ramp(0 ..< 500))
        XCTAssertEqual(block?.capturedAt, 9, "a block is stamped with its last batch")
        XCTAssertNil(backlog.pop(maxSamples: .max))
        XCTAssertEqual(backlog.snapshot.pushedSamples, 500)
        XCTAssertEqual(backlog.snapshot.droppedSamples, 0)
    }

    func testOverflowDropsExactlyTheOldestAndCountsIt() {
        let backlog = LiveAudioBacklog(capacity: 100)
        backlog.push(ramp(0 ..< 40), capturedAt: 1)
        backlog.push(ramp(40 ..< 80), capturedAt: 2)
        backlog.push(ramp(80 ..< 120), capturedAt: 3)

        XCTAssertEqual(backlog.snapshot.droppedSamples, 40)
        XCTAssertEqual(backlog.snapshot.maxPendingSamples, 80)
        XCTAssertEqual(backlog.pop(maxSamples: .max)?.samples, ramp(40 ..< 120))
    }

    func testNewestBatchSurvivesEvenWhenItAloneExceedsCapacity() {
        let backlog = LiveAudioBacklog(capacity: 10)
        backlog.push(ramp(0 ..< 50), capturedAt: 1)
        XCTAssertEqual(backlog.snapshot.droppedSamples, 0)

        backlog.push(ramp(50 ..< 100), capturedAt: 2)
        XCTAssertEqual(backlog.snapshot.droppedSamples, 50)
        XCTAssertEqual(backlog.pop(maxSamples: .max)?.samples, ramp(50 ..< 100))
    }

    func testPopStopsAtAWholeBatch() {
        let backlog = LiveAudioBacklog(capacity: 1000)
        backlog.push(ramp(0 ..< 30), capturedAt: 1)
        backlog.push(ramp(30 ..< 60), capturedAt: 2)
        backlog.push(ramp(60 ..< 90), capturedAt: 3)

        let first = backlog.pop(maxSamples: 70)
        XCTAssertEqual(first?.samples, ramp(0 ..< 60))
        XCTAssertEqual(first?.capturedAt, 2)
        let second = backlog.pop(maxSamples: 70)
        XCTAssertEqual(second?.samples, ramp(60 ..< 90))
        XCTAssertEqual(second?.capturedAt, 3)
        XCTAssertNil(backlog.pop(maxSamples: 70))
    }

    func testABatchLargerThanTheRequestComesWhole() {
        let backlog = LiveAudioBacklog(capacity: 1000)
        backlog.push(ramp(0 ..< 100), capturedAt: 1)
        XCTAssertEqual(backlog.pop(maxSamples: 10)?.samples.count, 100)
    }

    func testEmptyBatchIsIgnored() {
        let backlog = LiveAudioBacklog(capacity: 1000)
        backlog.push([], capturedAt: 1)
        XCTAssertNil(backlog.pop(maxSamples: .max))
        XCTAssertEqual(backlog.snapshot.pushedSamples, 0)
    }

    /// Thousands of small pops walk the head past the compaction threshold
    /// while batches are still waiting behind it.
    func testOrderSurvivesCompaction() {
        let backlog = LiveAudioBacklog(capacity: .max)
        for index in 0 ..< 2000 {
            backlog.push([Float(index)], capturedAt: Double(index))
        }
        var seen: [Float] = []
        while let block = backlog.pop(maxSamples: 3) {
            seen.append(contentsOf: block.samples)
        }
        XCTAssertEqual(seen, ramp(0 ..< 2000))
    }

    func testFeedTimeIsSummedAndItsWorstKept() {
        let backlog = LiveAudioBacklog()
        backlog.noteFeed(seconds: 0.001)
        backlog.noteFeed(seconds: 0.004)
        backlog.noteFeed(seconds: 0.002)

        let stats = backlog.snapshot
        XCTAssertEqual(stats.callbacks, 3)
        XCTAssertEqual(stats.feedSeconds, 0.007, accuracy: 1e-9)
        XCTAssertEqual(stats.maxFeedSeconds, 0.004, accuracy: 1e-9)
    }

    /// A producer and a consumer on different threads, as the tap and the feed
    /// loop are: every sample arrives once and in order.
    func testConcurrentPushAndPopLoseNothing() async {
        let backlog = LiveAudioBacklog(capacity: .max)
        let batches = 5000

        let producer = Task.detached {
            for index in 0 ..< batches {
                backlog.push([Float(index)], capturedAt: Double(index))
            }
        }
        let consumer = Task.detached { () -> [Float] in
            var seen: [Float] = []
            while seen.count < batches {
                if let block = backlog.pop(maxSamples: 64) {
                    seen.append(contentsOf: block.samples)
                } else {
                    await Task.yield()
                }
            }
            return seen
        }

        await producer.value
        let seen = await consumer.value
        XCTAssertEqual(seen, ramp(0 ..< batches))
        XCTAssertEqual(backlog.snapshot.droppedSamples, 0)
    }
}
