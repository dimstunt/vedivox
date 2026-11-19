import XCTest

/// The projection rule of `transcript-exclusion-marks` (design D2): ≥50% of a
/// segment's duration under excluded state hides it, later marks override
/// earlier ones, the default is include, and marks act only on their own track.
final class ExclusionProjectionTests: XCTestCase {
    private func mark(
        _ start: Double,
        _ end: Double?,
        kind: MarkKind = .excluded,
        track: SegmentSource = .mic,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        id: Int64? = nil
    ) -> MeetingMark {
        MeetingMark(
            id: id,
            meetingId: "m",
            startTime: start,
            endTime: end,
            track: track,
            kind: kind,
            source: .manual,
            createdAt: createdAt
        )
    }

    private func excluded(
        _ start: Double, _ end: Double,
        track: SegmentSource = .mic,
        marks: [MeetingMark]
    ) -> Bool {
        ExclusionProjection.isExcluded(
            segmentStart: start, segmentEnd: end, track: track, marks: marks
        )
    }

    // MARK: Coverage threshold

    func testNoMarksKeepsSegment() {
        XCTAssertFalse(excluded(0, 10, marks: []))
    }

    func testPartialOverlapBelowHalfKeepsSegment() {
        // Interval covers 3s of a 10s segment.
        XCTAssertFalse(excluded(0, 10, marks: [mark(0, 3)]))
    }

    func testOverlapAtExactlyHalfExcludes() {
        XCTAssertTrue(excluded(0, 10, marks: [mark(0, 5)]))
    }

    func testFullCoverageExcludes() {
        XCTAssertTrue(excluded(2, 8, marks: [mark(0, 100)]))
    }

    func testTwoIntervalsSumTheirCoverage() {
        // 3s + 3s of a 10s segment = 60% → excluded.
        XCTAssertTrue(excluded(0, 10, marks: [mark(0, 3), mark(7, 10)]))
    }

    // MARK: Later mark wins

    func testIncludedInsideExcludedReturnsSegment() {
        let big = mark(0, 100, createdAt: Date(timeIntervalSince1970: 0))
        let back = mark(
            2, 8, kind: .included,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        // Segment fully inside the included window → visible again.
        XCTAssertFalse(excluded(2, 8, marks: [big, back]))
        // A sibling segment outside the included window stays hidden.
        XCTAssertTrue(excluded(10, 20, marks: [big, back]))
    }

    func testLaterExcludedOverridesEarlierIncluded() {
        let back = mark(0, 10, kind: .included, createdAt: Date(timeIntervalSince1970: 0))
        let exclude = mark(0, 10, createdAt: Date(timeIntervalSince1970: 5))
        XCTAssertTrue(excluded(0, 10, marks: [back, exclude]))
    }

    func testSameTimestampFallsBackToIdOrder() {
        let ts = Date(timeIntervalSince1970: 42)
        let exclude = mark(0, 10, createdAt: ts, id: 1)
        let back = mark(0, 10, kind: .included, createdAt: ts, id: 2)
        XCTAssertFalse(excluded(0, 10, marks: [exclude, back]))
    }

    // MARK: Tracks

    func testMarkActsOnlyOnItsOwnTrack() {
        let micMark = mark(0, 100, track: .mic)
        XCTAssertTrue(excluded(0, 10, track: .mic, marks: [micMark]))
        XCTAssertFalse(excluded(0, 10, track: .system, marks: [micMark]))
    }

    // MARK: Open interval (recording-time button)

    func testOpenIntervalExtendsToSegmentEnd() {
        XCTAssertTrue(excluded(50, 60, marks: [mark(40, nil)]))
        XCTAssertFalse(excluded(0, 30, marks: [mark(40, nil)]))
    }

    // MARK: Degenerate input

    func testZeroLengthSegmentIsNeverExcluded() {
        XCTAssertFalse(excluded(5, 5, marks: [mark(0, 10)]))
    }
}

/// DB-level behaviour: reprojection writes the cache, reports flipped segments
/// and the speakers whose canonicals went stale.
final class MarkRepositoryTests: XCTestCase {
    private var db: DatabaseManager!
    private var meetings: MeetingRepository!
    private var marks: MarkRepository!

    override func setUp() async throws {
        db = try makeTestDB()
        meetings = MeetingRepository(db: db)
        marks = MarkRepository(db: db)
    }

    private func makeMeetingWithSegments() async throws -> (Meeting, [TranscriptSegment]) {
        let meeting = makeMeeting()
        try await meetings.save(meeting)
        try await db.writer.write { db in
            try makeSpeaker(id: "sp-1", name: "One").insert(db)
            try makeSpeaker(id: "sp-2", name: "Two").insert(db)
        }
        let segments = [
            makeSegment(meetingId: meeting.id, speakerId: "sp-1", source: .mic, startTime: 0, endTime: 10),
            makeSegment(meetingId: meeting.id, speakerId: "sp-2", source: .mic, startTime: 10, endTime: 20),
            makeSegment(meetingId: meeting.id, source: .system, startTime: 0, endTime: 20),
        ]
        try await meetings.saveSegments(segments)
        return (meeting, try await meetings.segments(for: meeting.id))
    }

    func testReprojectSetsAndClearsCache() async throws {
        let (meeting, _) = try await makeMeetingWithSegments()
        let mark = try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 12))

        let result = try await marks.reproject(meetingId: meeting.id)
        XCTAssertEqual(result.changedSegmentIds.count, 1, "только первый mic-сегмент покрыт на ≥50%")
        XCTAssertEqual(result.affectedSpeakerIds, ["sp-1"])

        var segments = try await meetings.segments(for: meeting.id)
        XCTAssertEqual(segments.filter(\.isExcluded).count, 1)
        XCTAssertTrue(segments.first(where: { $0.source == .mic && $0.startTime == 0 })!.isExcluded)
        XCTAssertFalse(segments.first(where: { $0.source == .system })!.isExcluded, "system-дорожку mic-пометка не трогает")

        // Removing the mark clears the cache on the next reprojection.
        try await marks.delete(id: mark.id!, meetingId: meeting.id)
        let cleared = try await marks.reproject(meetingId: meeting.id)
        XCTAssertEqual(cleared.affectedSpeakerIds, ["sp-1"])
        segments = try await meetings.segments(for: meeting.id)
        XCTAssertTrue(segments.allSatisfy { !$0.isExcluded })
    }

    func testReprojectIsIdempotent() async throws {
        let (meeting, _) = try await makeMeetingWithSegments()
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 12))

        _ = try await marks.reproject(meetingId: meeting.id)
        let second = try await marks.reproject(meetingId: meeting.id)
        XCTAssertTrue(second.changedSegmentIds.isEmpty)
        XCTAssertTrue(second.affectedSpeakerIds.isEmpty)
    }

    func testCloseOpenButtonMarks() async throws {
        let (meeting, _) = try await makeMeetingWithSegments()
        try await marks.add(MeetingMark(
            meetingId: meeting.id, startTime: 5, endTime: nil, source: .button
        ))

        let open = try await marks.openButtonMark(meetingId: meeting.id)
        XCTAssertNotNil(open)

        let closed = try await marks.closeOpenButtonMarks(meetingId: meeting.id, at: 15)
        XCTAssertEqual(closed, 1)
        let stillOpen = try await marks.openButtonMark(meetingId: meeting.id)
        XCTAssertNil(stillOpen)

        let all = try await marks.marks(for: meeting.id)
        XCTAssertEqual(all.first?.endTime, 15)
    }

    func testCloseNeverProducesNegativeInterval() async throws {
        let (meeting, _) = try await makeMeetingWithSegments()
        try await marks.add(MeetingMark(
            meetingId: meeting.id, startTime: 30, endTime: nil, source: .button
        ))
        // Stop before the lookback-shifted start: interval collapses to zero
        // length instead of going negative.
        _ = try await marks.closeOpenButtonMarks(meetingId: meeting.id, at: 10)
        let all = try await marks.marks(for: meeting.id)
        XCTAssertEqual(all.first?.endTime, 30)
    }

    func testDeletingMeetingCascadesMarks() async throws {
        let (meeting, _) = try await makeMeetingWithSegments()
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 5))

        try await meetings.delete(meeting.id)
        let remaining = try await marks.marks(for: meeting.id)
        XCTAssertTrue(remaining.isEmpty)
    }
}
