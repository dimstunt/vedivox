import XCTest

/// the Split sheet opens the cut at the turn being played and steps by turns.
final class SplitCutPointTests: XCTestCase {
    private let starts: [Double] = [0, 10, 25, 40]

    func testOpensAtStartOfPlayingSegment() {
        XCTAssertEqual(SplitCutPoint.initial(playhead: 31, segmentStarts: starts, duration: 60), 25)
    }

    func testOpensInTheMiddleWhenNothingPlayed() {
        XCTAssertEqual(SplitCutPoint.initial(playhead: nil, segmentStarts: starts, duration: 60), 30)
        XCTAssertEqual(SplitCutPoint.initial(playhead: 0, segmentStarts: starts, duration: 60), 30)
    }

    func testFirstSegmentStillLeavesASecond() {
        XCTAssertEqual(SplitCutPoint.initial(playhead: 5, segmentStarts: starts, duration: 60), 1)
    }

    func testSegmentStepsGoToNeighbouringStarts() {
        XCTAssertEqual(SplitCutPoint.segmentStep(from: 25, segmentStarts: starts, forward: true, duration: 60), 40)
        XCTAssertEqual(SplitCutPoint.segmentStep(from: 25, segmentStarts: starts, forward: false, duration: 60), 10)
        XCTAssertEqual(SplitCutPoint.segmentStep(from: 30, segmentStarts: starts, forward: false, duration: 60), 25)
        XCTAssertEqual(SplitCutPoint.segmentStep(from: 40, segmentStarts: starts, forward: true, duration: 60), 40,
                       "после последней реплики шагать некуда")
    }
}

/// Trim's bounds step like Split's cut — the start to turn starts,
/// the end to turn ends — and never come within a second of each other.
final class TrimBoundStepTests: XCTestCase {
    private let segments: [(start: Double, end: Double)] = [(0, 8), (10, 22), (25, 38), (40, 55)]

    func testStartStepsToTurnStartsAndStopsBeforeTheEnd() {
        let starts = segments.map(\.start)
        XCTAssertEqual(TrimBound.segmentStep(from: 0, stops: starts, forward: true, within: 0 ... 39), 10)
        XCTAssertEqual(TrimBound.segmentStep(from: 25, stops: starts, forward: false, within: 0 ... 39), 10)
        XCTAssertEqual(TrimBound.segmentStep(from: 25, stops: starts, forward: true, within: 0 ... 39), 39,
                       "следующая реплика за концом: начало упирается в конец минус секунда")
    }

    func testEndStepsToTurnEnds() {
        let ends = segments.map(\.end)
        XCTAssertEqual(TrimBound.segmentStep(from: 60, stops: ends, forward: false, within: 11 ... 60), 55)
        XCTAssertEqual(TrimBound.segmentStep(from: 38, stops: ends, forward: false, within: 11 ... 60), 22)
        XCTAssertEqual(TrimBound.segmentStep(from: 22, stops: ends, forward: false, within: 11 ... 60), 11)
        XCTAssertEqual(TrimBound.segmentStep(from: 55, stops: ends, forward: true, within: 11 ... 60), 55,
                       "после последней реплики шагать некуда")
    }

    func testSecondStepsStayInRange() {
        XCTAssertEqual(TrimBound.clamped(0 - 1, within: 0 ... 39), 0)
        XCTAssertEqual(TrimBound.clamped(39 + 1, within: 0 ... 39), 39)
        XCTAssertEqual(TrimBound.clamped(20 + 1, within: 0 ... 39), 21)
    }
}

/// The Trim sheet's «keeps N, deletes M» is what `MeetingRepository.trimMeeting`
/// then does: a turn a bound cuts through stays (clamped), only a turn wholly
/// outside goes. The preview used to count such a turn as deleted, and with one
/// long turn around both bounds it said «keeps 0» and Apply was off.
final class TrimPreviewCountTests: XCTestCase {
    func testPreviewCountsWhatTrimDeletes() async throws {
        let meetings = MeetingRepository(db: try makeTestDB())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-trim-count-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = makeMeeting()
        meeting.durationSeconds = 100
        try await meetings.save(meeting)
        // Outside, across the start, inside, across the end, outside.
        let spans: [(start: Double, end: Double)] = [(0, 10), (15, 30), (30, 70), (70, 85), (90, 100)]
        try await meetings.saveSegments(spans.map { makeSegment(meetingId: meeting.id, startTime: $0.start, endTime: $0.end) })

        let counts = TrimBound.counts(segments: spans, from: 20, to: 80)
        try await meetings.trimMeeting(meeting.id, keepFrom: 20, keepTo: 80, audioRoot: root)

        let kept = try await meetings.segments(for: meeting.id).count
        XCTAssertEqual(kept, 3)
        XCTAssertEqual(counts.keep, kept)
        XCTAssertEqual(counts.remove, spans.count - kept)
    }

    func testOneLongTurnAroundBothBoundsIsKept() {
        XCTAssertEqual(TrimBound.counts(segments: [(0, 60)], from: 10, to: 50).keep, 1)
    }

    func testATurnThatOnlyTouchesABoundIsDeleted() {
        let counts = TrimBound.counts(segments: [(0, 10), (50, 60)], from: 10, to: 50)
        XCTAssertEqual(counts.keep, 0)
        XCTAssertEqual(counts.remove, 2)
    }
}
