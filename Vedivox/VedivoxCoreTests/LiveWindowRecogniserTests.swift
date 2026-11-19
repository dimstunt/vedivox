import os
import XCTest

/// One track's live recognition over windows (live-transcript D1, D5), with the
/// model replaced by a stub: which audio reaches it, and what times the text
/// gets on the recording's clock.
final class LiveWindowRecogniserTests: XCTestCase {

    private struct Failure: Error {}

    /// Records the windows it is given and answers «окно N» as one segment
    /// lying 0.5…1.5 s into the window, unless told what to answer.
    private final class Model: Sendable {
        private let windows = OSAllocatedUnfairLock(initialState: [Int]())
        let failing: Set<Int>
        let answer: (@Sendable (Int) -> [TokenGrouper.Segment])?

        init(failing: Set<Int> = [], answer: (@Sendable (Int) -> [TokenGrouper.Segment])? = nil) {
            self.failing = failing
            self.answer = answer
        }

        var sizes: [Int] { windows.withLock { $0 } }

        func transcribe(_ samples: [Float]) throws -> [TokenGrouper.Segment] {
            let index = windows.withLock { sizes in
                sizes.append(samples.count)
                return sizes.count - 1
            }
            if failing.contains(index) { throw Failure() }
            return answer?(index) ?? [.init(startTime: 0.5, endTime: 1.5, text: "окно \(index)", confidence: nil)]
        }
    }

    private func speech(_ seconds: Double) -> [Float] {
        (0 ..< Int(seconds * 16000)).map { 0.3 * sinf(2 * .pi * 220 * Float($0) / 16000) }
    }

    private func quiet(_ seconds: Double) -> [Float] {
        (0 ..< Int(seconds * 16000)).map { 0.002 * sinf(2 * .pi * 50 * Float($0) / 16000) }
    }

    /// Feeds `audio` a quarter of a second at a time, as the feed loop does,
    /// starting at `from` seconds into the recording.
    private func feed(_ audio: [Float], to recogniser: LiveWindowRecogniser, from: Double = 0) async -> [LivePiece] {
        var pieces: [LivePiece] = []
        for offset in stride(from: 0, to: audio.count, by: 4000) {
            let end = min(offset + 4000, audio.count)
            pieces += await recogniser.append(Array(audio[offset ..< end]), endingAt: from + Double(end) / 16000)
        }
        return pieces
    }

    private func recogniser(_ model: Model) -> LiveWindowRecogniser {
        LiveWindowRecogniser(load: {}, transcribe: { try model.transcribe($0) })
    }

    func testReadinessFollowsTheModelLoad() async {
        let ready = LiveWindowRecogniser(load: {}, transcribe: { _ in [] })
        let loadingBefore = await ready.readiness
        XCTAssertEqual(loadingBefore, .loading)
        await ready.prepare()
        let readiness = await ready.readiness
        XCTAssertEqual(readiness, .ready)

        let broken = LiveWindowRecogniser(load: { throw Failure() }, transcribe: { _ in [] })
        await broken.prepare()
        let unavailable = await broken.readiness
        XCTAssertEqual(unavailable, .unavailable)
    }

    func testAPhraseIsCutAtItsPauseAndTimedOnTheRecordingClock() async {
        let model = Model()
        let pieces = await feed(speech(7) + quiet(1), to: recogniser(model), from: 100)

        XCTAssertEqual(pieces, [LivePiece(start: 100.5, end: 101.5, text: "окно 0")])
        let window = Double(model.sizes[0]) / 16000
        XCTAssertGreaterThan(window, 7.0)
        XCTAssertLessThan(window, 7.6)
    }

    /// A window can open with seconds of room noise: the phrase keeps the time
    /// it was said at, or an exclusion mark over it would not cover it.
    func testSegmentsKeepTheirOwnTimesInsideTheWindow() async {
        let model = Model(answer: { _ in
            [
                .init(startTime: 5.1, endTime: 6.4, text: " вопрос?", confidence: nil),
                .init(startTime: 6.6, endTime: 6.9, text: " да", confidence: nil),
            ]
        })
        let pieces = await feed(quiet(5) + speech(2) + quiet(1), to: recogniser(model), from: 50)

        XCTAssertEqual(pieces.map(\.text), [" вопрос?", " да"])
        XCTAssertEqual(pieces[0].start, 55.1, accuracy: 0.001)
        XCTAssertEqual(pieces[0].end, 56.4, accuracy: 0.001)
        XCTAssertEqual(pieces[1].start, 56.6, accuracy: 0.001)
    }

    func testConsecutivePhrasesGiveWindowsThatFollowEachOther() async {
        let model = Model()
        let audio = speech(7) + quiet(1) + speech(8) + quiet(1) + speech(6.5) + quiet(1)
        let pieces = await feed(audio, to: recogniser(model))

        XCTAssertEqual(pieces.map(\.text), ["окно 0", "окно 1", "окно 2"])
        // Each stub segment sits 0.5 s into its window, so the distance between
        // two pieces is the length of the earlier window: no gap, no overlap.
        for index in 0 ..< 2 {
            XCTAssertEqual(
                pieces[index + 1].start - pieces[index].start, Double(model.sizes[index]) / 16000, accuracy: 0.001
            )
        }
        XCTAssertEqual(pieces[0].start, 0.5, accuracy: 0.001)
    }

    func testSpeechWithoutPausesIsCutByTheWindowLimit() async {
        let model = Model()
        let pieces = await feed(speech(30), to: recogniser(model))

        XCTAssertGreaterThanOrEqual(pieces.count, 2)
        XCTAssertTrue(model.sizes.allSatisfy { $0 <= LiveWindowCutter.maxWindow })
    }

    /// A system track with nothing playing: no model calls, no growing buffer.
    func testDigitalSilenceNeverReachesTheModel() async {
        let model = Model()
        let pieces = await feed([Float](repeating: 0, count: 60 * 16000), to: recogniser(model))

        XCTAssertEqual(pieces, [])
        XCTAssertEqual(model.sizes, [])
    }

    func testAFailedWindowIsSkippedAndTheNextOneStillComes() async {
        let model = Model(failing: [0])
        let pieces = await feed(speech(7) + quiet(1) + speech(7) + quiet(1), to: recogniser(model))

        XCTAssertEqual(pieces.map(\.text), ["окно 1"])
        XCTAssertGreaterThan(pieces[0].start, 7)
    }
}
