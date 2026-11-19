import XCTest

/// The chopped-call-audio signature on synthetic callback
/// sequences: 48 kHz, 512 frames per callback, as the tap delivers.
final class TapChopDetectorTests: XCTestCase {
    private let rate = 48000.0
    private let buffer = 512

    /// Feeds `pattern` (true = all-zero buffer) cyclically for `seconds`.
    private func feed(_ detector: inout TapChopDetector, _ pattern: [Bool], seconds: Double) -> [TapChopDetector.Event] {
        let count = Int(seconds * rate) / buffer
        return (0 ..< count).compactMap { detector.add(zero: pattern[$0 % pattern.count], frames: buffer) }
    }

    /// 18.11: 6 all-zero buffers of every 15 — one 160 ms cycle.
    private let chop = Array(repeating: true, count: 6) + Array(repeating: false, count: 9)

    func testTheIncidentCycleIsCaughtAfterTenSeconds() {
        var detector = TapChopDetector(sampleRate: rate)
        XCTAssertEqual(feed(&detector, chop, seconds: 9.5), [])
        let events = feed(&detector, chop, seconds: 30)
        XCTAssertEqual(events.count, 1)
        guard case .chopped(let again, let transitions, let zeroBuffers) = events.first else {
            return XCTFail("\(events)")
        }
        XCTAssertFalse(again)
        XCTAssertGreaterThanOrEqual(transitions, 12)
        XCTAssertGreaterThanOrEqual(zeroBuffers, 36)
        XCTAssertTrue(detector.chopped)
    }

    func testTheInverseCycleIsCaughtToo() {
        var detector = TapChopDetector(sampleRate: rate)
        XCTAssertEqual(feed(&detector, chop.map { !$0 }, seconds: 11).count, 1)
    }

    func testSpeechWithPausesIsNotAChop() {
        // 1.5 s of sound, 0.4 s of digital silence between phrases, for 2 minutes
        let speech = Array(repeating: false, count: 140) + Array(repeating: true, count: 38)
        var detector = TapChopDetector(sampleRate: rate)
        XCTAssertEqual(feed(&detector, speech, seconds: 120), [])
    }

    func testDigitalSilenceIsNotAChop() {
        var detector = TapChopDetector(sampleRate: rate)
        XCTAssertEqual(feed(&detector, [true], seconds: 60), [])
    }

    func testSingleDropoutsAndAShortBurstAreNotAChop() {
        // one zero buffer every ~2 s
        let dropouts = [true] + Array(repeating: false, count: 190)
        var detector = TapChopDetector(sampleRate: rate)
        XCTAssertEqual(feed(&detector, dropouts, seconds: 60), [])
        // 5 s of the chop between clean sound
        XCTAssertEqual(feed(&detector, chop, seconds: 5), [])
        XCTAssertEqual(feed(&detector, [false], seconds: 10), [])
        XCTAssertFalse(detector.chopped)
    }

    func testClearsAfterAMinuteOfCleanSoundSilenceNotCounted() {
        var detector = TapChopDetector(sampleRate: rate)
        XCTAssertEqual(feed(&detector, chop, seconds: 12).count, 1)
        // 16 s of other sound hiding the holes, as inside the 18.11 chop, then the chop again
        XCTAssertEqual(feed(&detector, [false], seconds: 16), [])
        XCTAssertEqual(feed(&detector, chop, seconds: 5), [])
        XCTAssertEqual(feed(&detector, [false], seconds: 58), [])
        // the call falls silent: neither proves nor breaks the recovery
        XCTAssertEqual(feed(&detector, [true], seconds: 20), [])
        XCTAssertTrue(detector.chopped)
        XCTAssertEqual(feed(&detector, [false], seconds: 4), [.cleared])
        XCTAssertFalse(detector.chopped)
    }

    func testARestartThatDidNotHelpReportsTheChopAgain() {
        var detector = TapChopDetector(sampleRate: rate)
        XCTAssertEqual(feed(&detector, chop, seconds: 12).count, 1)
        detector.restart()
        XCTAssertTrue(detector.chopped)
        let events = feed(&detector, chop, seconds: 11)
        guard events.count == 1, case .chopped(again: true, _, _) = events[0] else {
            return XCTFail("\(events)")
        }
    }

    func testCountsAreTakenOnce() {
        var detector = TapChopDetector(sampleRate: rate)
        _ = feed(&detector, chop, seconds: 1.6) // 150 buffers = 10 cycles
        let counts = detector.takeCounts()
        XCTAssertEqual(counts.zeroBuffers, 60)
        XCTAssertEqual(counts.transitions, 19)
        XCTAssertEqual(detector.takeCounts().zeroBuffers, 0)
    }
}
