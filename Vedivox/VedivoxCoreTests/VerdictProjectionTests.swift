import XCTest

/// The verdict rule on its own, without a database (listen-queue 2.1).
final class VerdictProjectionTests: XCTestCase {

    private func verdict(
        _ start: Double, _ end: Double, _ speaker: String?,
        track: SegmentSource = .system, kind: MarkKind = .speaker, at offset: TimeInterval = 0
    ) -> MeetingMark {
        MeetingMark(
            meetingId: "m", startTime: start, endTime: end, track: track, kind: kind,
            createdAt: Date(timeIntervalSince1970: 1_000 + offset), speakerId: speaker
        )
    }

    private func speaker(_ start: Double, _ end: Double, _ verdicts: [MeetingMark], track: SegmentSource = .system) -> String? {
        VerdictProjection.speakerId(segmentStart: start, segmentEnd: end, track: track, verdicts: verdicts)
    }

    func testSixtyPercentCoverage_goesToTheVerdictSpeaker() {
        XCTAssertEqual(speaker(0, 10, [verdict(4, 20, "alice")]), "alice")
    }

    func testThirtyPercentCoverage_leavesThePipelineAttribution() {
        XCTAssertNil(speaker(0, 10, [verdict(7, 20, "alice")]))
    }

    func testOverlap_laterVerdictWins() {
        let early = verdict(0, 10, "alice", at: 0)
        let late = verdict(0, 10, "carol", at: 60)
        XCTAssertEqual(speaker(2, 8, [late, early]), "carol")
    }

    func testPartialLaterVerdict_takesOnlyItsPart() {
        let early = verdict(0, 20, "alice", at: 0)
        let late = verdict(10, 20, "carol", at: 60)
        XCTAssertEqual(speaker(0, 8, [early, late]), "alice")
        XCTAssertEqual(speaker(12, 18, [early, late]), "carol")
        XCTAssertEqual(speaker(7, 14, [early, late]), "carol", "у Carol 4 с из 7, больше покрытой меры")
    }

    func testVerdictOfTheOtherTrack_doesNothing() {
        XCTAssertNil(speaker(0, 10, [verdict(0, 10, "alice", track: .mic)]))
    }

    func testSkipped_movesNothing() {
        XCTAssertNil(speaker(0, 10, [verdict(0, 10, nil, kind: .skipped)]))
        let named = verdict(0, 10, "alice", at: 0)
        let skipped = verdict(0, 10, nil, kind: .skipped, at: 60)
        XCTAssertNil(speaker(0, 10, [named, skipped]), "поздний пропуск перекрывает ранний вердикт")
    }

    func testVisibilityMarks_areIgnored() {
        let excluded = MeetingMark(meetingId: "m", startTime: 0, endTime: 10, track: .system)
        XCTAssertNil(speaker(0, 10, [excluded]))
    }

    func testAssignments_keysOnlyClaimedSegments() {
        var a = makeSegment(meetingId: "m", source: .system, startTime: 0, endTime: 10)
        a.id = 1
        var b = makeSegment(meetingId: "m", source: .system, startTime: 30, endTime: 40)
        b.id = 2
        XCTAssertEqual(VerdictProjection.assignments(segments: [a, b], verdicts: [verdict(0, 10, "alice")]), [1: "alice"])
    }
}
