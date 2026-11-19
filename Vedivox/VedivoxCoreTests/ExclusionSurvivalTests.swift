import XCTest

/// Marks are the source of truth and must survive everything that rewrites or
/// shifts segments: reprocess, trim, split (transcript-exclusion-marks, group 2).
final class ExclusionSurvivalTests: XCTestCase {
    private var db: DatabaseManager!
    private var meetings: MeetingRepository!
    private var marks: MarkRepository!
    private var tempRoot: URL!

    override func setUp() async throws {
        db = try makeTestDB()
        meetings = MeetingRepository(db: db)
        marks = MarkRepository(db: db)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-exclusion-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func markTimes(_ meetingId: String) async throws -> [(Double, Double?)] {
        try await marks.marks(for: meetingId).map { ($0.startTime, $0.endTime) }
    }

    // MARK: Reprocess

    func testMarksSurviveReprocessAndReapply() async throws {
        let meeting = makeMeeting()
        try await meetings.save(meeting)
        try await meetings.saveSegments([
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 0, endTime: 10),
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 10, endTime: 20),
        ])
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 10))
        _ = try await marks.reproject(meetingId: meeting.id)

        // Reprocess deletes and recreates segments with fresh ids — exactly
        // what AppState.reprocessMeeting does before rerunning the pipeline.
        try await meetings.deleteSegmentsAndSpeakers(for: meeting.id)
        let survivors = try await marks.marks(for: meeting.id)
        XCTAssertEqual(survivors.count, 1, "пометка живёт отдельно от сегментов")

        try await meetings.saveSegments([
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 0, endTime: 9),
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 9, endTime: 20),
        ])
        _ = try await marks.reproject(meetingId: meeting.id)

        let segments = try await meetings.segments(for: meeting.id)
        XCTAssertTrue(segments.first(where: { $0.startTime == 0 })!.isExcluded, "тот же интервал времени снова скрыт")
        XCTAssertFalse(segments.first(where: { $0.startTime == 9 })!.isExcluded)
    }

    // MARK: Whole mic track

    /// One mark hides the mic track and leaves the system one; restoring takes
    /// exactly that mark away, so a line the user hid by hand stays hidden.
    func testWholeMicTrackIsExcludedAndRestoredByOneMark() async throws {
        let meeting = makeMeeting()
        try await meetings.save(meeting)
        try await meetings.saveSegments([
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 0, endTime: 10, text: "mic1"),
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 20, endTime: 30, text: "mic2"),
            makeSegment(meetingId: meeting.id, source: .system, startTime: 5, endTime: 25, text: "sys"),
        ])
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 20, endTime: 30))
        _ = try await marks.reproject(meetingId: meeting.id)
        func hidden() async throws -> Set<String> {
            Set(try await meetings.segments(for: meeting.id).filter(\.isExcluded).map(\.text))
        }

        try await marks.excludeWholeTrack(meetingId: meeting.id, track: .mic, end: 30)
        let laid = try await marks.marks(for: meeting.id)
        XCTAssertEqual(laid.count, 2, "one mark for the whole track, not one per line")
        XCTAssertEqual(laid.filter { MarkRepository.hidesWholeTrack($0, .mic, end: 30) }.count, 1)
        let hiddenAll = try await hidden()
        XCTAssertEqual(hiddenAll, ["mic1", "mic2"])

        try await marks.restoreWholeTrack(meetingId: meeting.id, track: .mic, end: 30)
        let left = try await marks.marks(for: meeting.id)
        XCTAssertEqual(left.count, 1)
        let hiddenAfter = try await hidden()
        XCTAssertEqual(hiddenAfter, ["mic2"], "the hand-made mark is still there")
    }

    // MARK: Trim

    func testTrimShiftsCutsAndDropsMarks() async throws {
        var meeting = makeMeeting()
        meeting.durationSeconds = 100
        try await meetings.save(meeting)
        try await meetings.saveSegments([
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 25, endTime: 75),
        ])
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 10)) // fully before → dropped
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 30, endTime: 50)) // inside → shifted
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 70, endTime: nil, source: .button)) // open → shifted, stays open
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 85, endTime: 95)) // fully after → dropped

        try await meetings.trimMeeting(meeting.id, keepFrom: 20, keepTo: 80, audioRoot: tempRoot)

        let times = try await markTimes(meeting.id).sorted { $0.0 < $1.0 }
        XCTAssertEqual(times.count, 2)
        XCTAssertEqual(times[0].0, 10)
        XCTAssertEqual(times[0].1, 30)
        XCTAssertEqual(times[1].0, 50)
        XCTAssertNil(times[1].1, "открытый интервал остаётся открытым после trim")
    }

    // MARK: Split

    func testSplitDistributesMarksAndUndoRestoresCoverage() async throws {
        var meeting = makeMeeting()
        meeting.durationSeconds = 100
        try await meetings.save(meeting)
        try await meetings.saveSegments([
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 0, endTime: 45),
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 55, endTime: 100),
        ])
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 10, endTime: 20)) // left half
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 40, endTime: 60)) // spans the cut
        try await marks.add(MeetingMark(meetingId: meeting.id, startTime: 80, endTime: 90)) // right half

        let (m1, m2) = try await meetings.splitMeeting(meeting.id, atTime: 50, audioRoot: tempRoot)

        let left = try await markTimes(m1.id).sorted { $0.0 < $1.0 }
        XCTAssertEqual(left.map(\.0), [10, 40])
        XCTAssertEqual(left.compactMap(\.1), [20, 50], "перекрывающий интервал подрезан в левой половине")

        let right = try await markTimes(m2.id).sorted { $0.0 < $1.0 }
        XCTAssertEqual(right.map(\.0), [0, 30])
        XCTAssertEqual(right.compactMap(\.1), [10, 40], "перекрывающий интервал сдвинут в правой половине")

        try await meetings.undoSplit(m1.id, audioRoot: tempRoot)

        // Coverage equivalent to the original three intervals (the spanning
        // one comes back as two adjacent pieces).
        let restored = try await markTimes(m1.id).sorted { $0.0 < $1.0 }
        XCTAssertEqual(restored.map(\.0), [10, 40, 50, 80])
        XCTAssertEqual(restored.compactMap(\.1), [20, 50, 60, 90])
        let orphaned = try await markTimes(m2.id)
        XCTAssertTrue(orphaned.isEmpty)
    }

    /// listen-queue 1.3: a verdict spanning the cut lands in both halves with
    /// the same speaker, shifted in the second.
    func testSplitCarriesTheVerdictSpeaker() async throws {
        let alice = makeSpeaker(name: "Alice")
        try await SpeakerRepository(db: db).save(alice)
        var meeting = makeMeeting()
        meeting.durationSeconds = 100
        try await meetings.save(meeting)
        try await meetings.saveSegments([
            makeSegment(meetingId: meeting.id, source: .system, startTime: 0, endTime: 45),
            makeSegment(meetingId: meeting.id, source: .system, startTime: 55, endTime: 100),
        ])
        try await marks.add(MeetingMark(
            meetingId: meeting.id, startTime: 40, endTime: 60, track: .system, kind: .speaker, speakerId: alice.id
        ))

        let (m1, m2) = try await meetings.splitMeeting(meeting.id, atTime: 50, audioRoot: tempRoot)

        let left = try await marks.verdicts(for: m1.id)
        let right = try await marks.verdicts(for: m2.id)
        XCTAssertEqual(left.map(\.speakerId), [alice.id])
        XCTAssertEqual(right.map(\.speakerId), [alice.id])
        XCTAssertEqual(right.first?.startTime, 0)
        XCTAssertEqual(right.first?.endTime, 10)
    }
}
