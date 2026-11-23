import XCTest

/// The «who moved where» line logged after a reprocess.
final class ReprocessReportTests: XCTestCase {
    private let names = ["a1": "speaker_1", "al": "Alice", "bo": "Bob", "me": "Me"]

    private func line(_ id: String?, _ start: Double, _ end: Double, _ source: SegmentSource, hidden: Bool = false)
        -> TranscriptSegment
    {
        var line = makeSegment(meetingId: "m", speakerId: id, source: source, startTime: start, endTime: end)
        line.isExcluded = hidden
        return line
    }

    func testMixedTrackSplitIntoPeople() {
        let before = [line("a1", 0, 100, .merged), line("al", 100, 200, .merged)]
        let after = [
            line("al", 0, 60, .system), line("bo", 60, 100, .system), line("al", 100, 200, .system),
            line("me", 150, 160, .mic),
        ]

        let report = ReprocessReport(before: before, after: after, names: names)

        XCTAssertEqual(report.anonymousBefore, 100)
        XCTAssertEqual(report.anonymousAfter, 0)
        XCTAssertEqual(report.moved, 110)
        XCTAssertEqual(report.total, 210)
        XCTAssertEqual(report.moves, [
            .init(from: "speaker_1", to: "Alice", seconds: 60),
            .init(from: "speaker_1", to: "Bob", seconds: 40),
            .init(from: "Alice", to: "Me", seconds: 10),
        ])
        XCTAssertEqual(report.summary,
                       "anonymous 1.7 → 0.0 min, 1.8 of 3.5 min changed hands: "
                           + "speaker_1 → Alice 1.0, speaker_1 → Bob 0.7, Alice → Me 0.2")
    }

    func testSeparateTracksDoNotCross_smallAndHiddenMoves() {
        let before = [line("al", 0, 10, .mic), line("bo", 20, 22, .system), line("a1", 30, 40, .system)]
        let after = [
            line("bo", 0, 10, .system), // other track: no move
            line("al", 20, 22, .system), // 2 s: below the floor
            line("a1", 30, 40, .system, hidden: true), // hidden now
        ]

        let report = ReprocessReport(before: before, after: after, names: names)

        XCTAssertEqual(report.moves, [.init(from: "speaker_1", to: "speaker_1 (hidden)", seconds: 10)])
        XCTAssertEqual(report.moved, 12, "мелкое перемещение считается в сумме, но не в списке")
        XCTAssertEqual(report.anonymousAfter, 0, "скрытые реплики безымянной речью не считаются")
    }

    func testUnknownIdFallsBackToTheLineLabel() {
        var gone = line("deleted", 0, 30, .system)
        gone.speakerLabel = "speaker_7"
        let report = ReprocessReport(before: [gone], after: [line("al", 0, 30, .system)], names: names)
        XCTAssertEqual(report.moves, [.init(from: "speaker_7", to: "Alice", seconds: 30)])
        XCTAssertEqual(report.anonymousBefore, 30)
    }
}
