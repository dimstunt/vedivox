import os
import XCTest

/// The live text in the window of the meeting being recorded (live-transcript
/// D9): what the window shows in each state, and when it follows the speaker.
@MainActor
final class LiveTranscriptScreenModelTests: XCTestCase {

    private func turn(
        _ start: Double, _ text: String, _ speaker: LiveSpeaker = .others, track: SegmentSource = .system
    ) -> LiveTranscriptLog.Turn {
        .init(track: track, speaker: speaker, start: start, end: start + 4, text: text)
    }

    func testNothingIsShownBeforeTheFirstReading() {
        XCTAssertNil(LiveTranscriptScreenModel().content)
    }

    func testARecordingWithoutLiveTranscriptKeepsTheOldNotice() {
        let model = LiveTranscriptScreenModel()
        model.show(nil)
        XCTAssertEqual(model.content, .off)
    }

    func testBeforeAnybodySpeaksItListens() {
        let model = LiveTranscriptScreenModel()
        model.show([])
        XCTAssertEqual(model.content, .listening)
    }

    func testTurnsBecomeRowsWithSpeakerAndClock() {
        let model = LiveTranscriptScreenModel()
        let alice = LiveSpeaker(kind: .known, name: "Alice", confidence: 0.8)
        model.show([turn(67, "какой у нас срок?", alice), turn(3725, "до пятницы", .me, track: .mic)])

        guard case .turns(let rows) = model.content else { return XCTFail("expected turns") }
        XCTAssertEqual(rows.map(\.speaker.name), ["Alice", "me"])
        XCTAssertEqual(rows.map(\.time), ["1:07", "1:02:05"])
        XCTAssertEqual(rows.map(\.text), ["какой у нас срок?", "до пятницы"])
    }

    /// The same turn with more text is the same row: the list updates it in
    /// place instead of dropping and re-adding it.
    func testAGrowingTurnKeepsItsRow() {
        let model = LiveTranscriptScreenModel()
        model.show([turn(10, "первое")])
        guard case .turns(let before) = model.content else { return XCTFail("expected turns") }
        model.show([turn(10, "первое второе")])
        guard case .turns(let after) = model.content else { return XCTFail("expected turns") }

        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(after.map(\.text), ["первое второе"])
    }

    // MARK: Following the speaker

    func testNewTextScrollsIntoViewWhileTheReaderIsAtTheEnd() {
        let model = LiveTranscriptScreenModel()
        model.show([turn(10, "раз")])
        let first = model.scrollTick
        model.show([turn(10, "раз"), turn(20, "два")])
        XCTAssertGreaterThan(model.scrollTick, first)
    }

    func testAReaderWhoScrolledUpIsLeftWhereTheyAre() {
        let model = LiveTranscriptScreenModel()
        model.show([turn(10, "раз")])
        model.readerScrolled(atEnd: false)
        let held = model.scrollTick

        model.show([turn(10, "раз"), turn(20, "два")])
        XCTAssertEqual(model.scrollTick, held, "reading earlier text is not interrupted")
        guard case .turns(let rows) = model.content else { return XCTFail("expected turns") }
        XCTAssertEqual(rows.count, 2, "the text itself still arrives")

        model.readerScrolled(atEnd: true)
        model.show([turn(10, "раз"), turn(20, "два"), turn(30, "три")])
        XCTAssertGreaterThan(model.scrollTick, held, "back at the end, following resumes")
    }

    func testAReadingThatChangesNothingDoesNotScroll() {
        let model = LiveTranscriptScreenModel()
        model.show([turn(10, "раз")])
        let tick = model.scrollTick
        model.show([turn(10, "раз")])
        XCTAssertEqual(model.scrollTick, tick)
    }

    // MARK: Reading

    func testFollowReadsUntilCancelledAndShowsWhatItRead() async {
        let model = LiveTranscriptScreenModel()
        let readings = OSAllocatedUnfairLock(initialState: 0)
        let spoken = turn(5, "слово")
        let task = Task {
            await model.follow(every: .milliseconds(10)) {
                let reading = readings.withLock { count -> Int in
                    count += 1
                    return count
                }
                return reading > 1 ? [spoken] : []
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while model.content != .turns([.init(spoken)]), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.content, .turns([.init(spoken)]), "listening first, then the turn")

        task.cancel()
        await task.value
        let stopped = readings.withLock { $0 }
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(readings.withLock { $0 }, stopped, "no reading after the window is gone")
    }

    /// a closed main window lingers invisible with its views alive,
    /// and the pane went on reading the live text every second.
    func testFollowDoesNotReadWhileTheWindowIsOffScreen() async {
        let model = LiveTranscriptScreenModel()
        let readings = OSAllocatedUnfairLock(initialState: 0)
        let onScreen = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await model.follow(
                every: .milliseconds(10),
                while: { onScreen.withLock { $0 } },
                read: {
                    readings.withLock { $0 += 1 }
                    return []
                }
            )
        }
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(readings.withLock { $0 }, 0, "off screen: nothing read")
        XCTAssertNil(model.content)

        onScreen.withLock { $0 = true }
        let deadline = Date().addingTimeInterval(5)
        while model.content == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.content, .listening, "back on screen, it reads again")

        task.cancel()
        await task.value
    }
}
