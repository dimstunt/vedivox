import XCTest

/// Dictation plaques land where the dictation happened among speaker runs.
final class TranscriptRowMergeTests: XCTestCase {

    private func run(at start: Double, id: Int64) -> SegmentRun {
        let segment = TranscriptSegment(
            id: id, meetingId: "m", speakerId: nil, speakerLabel: nil,
            source: .system, startTime: start, endTime: start + 5, text: "t",
            originalText: nil, isEdited: false, confidence: nil, embedding: nil
        )
        return SegmentRun(id: id, speakerId: nil, speakerLabel: nil, segments: [segment])
    }

    private func dictation(at start: Double, id: Int64) -> MeetingMark {
        MeetingMark(id: id, meetingId: "m", startTime: start, endTime: start + 3, source: .dictation, text: "d")
    }

    func testDictationsInterleaveByStartTime() {
        let rows = TranscriptRow.merge(
            [run(at: 0, id: 1), run(at: 10, id: 2), run(at: 20, id: 3)],
            dictations: [dictation(at: 25, id: 8), dictation(at: 10, id: 7), dictation(at: 4, id: 6)]
        )
        XCTAssertEqual(rows.map(\.id), [
            "run-1", "dictation-6", "dictation-7", "run-2", "run-3", "dictation-8",
        ])
    }

    func testNoRunsKeepsDictations() {
        XCTAssertEqual(TranscriptRow.merge([], dictations: [dictation(at: 1, id: 1)]).map(\.id), ["dictation-1"])
    }
}
