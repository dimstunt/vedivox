import XCTest

/// The shared «assign» / «skip» action (listen-queue 3.1).
final class SpeakerVerdictsTests: XCTestCase {

    private var db: DatabaseManager!
    private var meetingRepo: MeetingRepository!
    private var speakerRepo: SpeakerRepository!
    private var verdicts: SpeakerVerdicts!
    private var meeting: Meeting!
    private var anon: Speaker!

    /// An anonymous voice with two touching lines, a neighbour's line, then
    /// one more line of the voice: two contiguous runs.
    override func setUp() async throws {
        db = try makeTestDB()
        meetingRepo = MeetingRepository(db: db)
        speakerRepo = SpeakerRepository(db: db)
        verdicts = SpeakerVerdicts(db: db)
        meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        anon = makeSpeaker(name: "speaker_4")
        let neighbour = Speaker(nameEn: "Neighbour", isConfirmed: true)
        try await speakerRepo.save(anon)
        try await speakerRepo.save(neighbour)
        for speaker in [anon!, neighbour] {
            try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: speaker.id, diarizationLabel: speaker.nameEn)
        }
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: anon.id, speakerLabel: "speaker_4", source: .system, startTime: 0, endTime: 5),
            makeSegment(meetingId: meeting.id, speakerId: anon.id, speakerLabel: "speaker_4", source: .system, startTime: 5, endTime: 10),
            makeSegment(meetingId: meeting.id, speakerId: neighbour.id, speakerLabel: "Neighbour", source: .system, startTime: 10, endTime: 15),
            makeSegment(meetingId: meeting.id, speakerId: anon.id, speakerLabel: "speaker_4", source: .system, startTime: 15, endTime: 20),
        ])
    }

    private func anonSegmentIds() async throws -> [Int64] {
        try await meetingRepo.segments(for: meeting.id).filter { $0.speakerId == anon.id }.compactMap(\.id)
    }

    func testAssignExisting_movesLinesAndWritesOneVerdictPerRun() async throws {
        let alice = Speaker(nameEn: "Alice", isConfirmed: true)
        try await speakerRepo.save(alice)

        let outcome = try await verdicts.assign(
            meetingId: meeting.id, segmentIds: try await anonSegmentIds(), to: .existing(speakerId: alice.id)
        )

        XCTAssertEqual(outcome.segments, 3)
        XCTAssertEqual(outcome.seconds, 15)
        XCTAssertEqual(outcome.intervals, 2, "две непрерывные пачки — два интервала")
        let marks = try await MarkRepository(db: db).verdicts(for: meeting.id)
        XCTAssertEqual(marks.map { [$0.startTime, $0.endTime ?? -1] }, [[0, 10], [15, 20]])
        XCTAssertTrue(marks.allSatisfy { $0.speakerId == alice.id && $0.kind == .speaker && $0.source == .manual })
        XCTAssertEqual(Set(marks.map(\.createdAt)).count, 1, "одно решение — один createdAt")
        let gone = try await speakerRepo.find(anon.id)
        XCTAssertNil(gone, "донор-аноним без реплик удалён")
        XCTAssertTrue(outcome.donors.isEmpty)
        XCTAssertNotNil(outcome.target[.v1])
        let linked = Set(try await speakerRepo.speakersForMeeting(meeting.id).map(\.speaker.nameEn))
        XCTAssertEqual(linked, ["Alice", "Neighbour"])
    }

    func testAssignNew_withAnExistingName_landsOnThatRecord() async throws {
        let existing = Speaker(nameEn: "Hugo Lane", isConfirmed: false)
        try await speakerRepo.save(existing)

        let outcome = try await verdicts.assign(
            meetingId: meeting.id, segmentIds: try await anonSegmentIds(), to: .new(name: "Hugo Lane")
        )

        XCTAssertEqual(outcome.speaker.id, existing.id)
        let confirmed = try await speakerRepo.find(existing.id)
        XCTAssertEqual(confirmed?.isConfirmed, true)
    }

    func testAssignNew_unknownName_createsConfirmedRecord() async throws {
        let outcome = try await verdicts.assign(
            meetingId: meeting.id, segmentIds: try await anonSegmentIds(), to: .new(name: "Ella")
        )
        let created = try await speakerRepo.find(outcome.speaker.id)
        XCTAssertEqual(created?.nameEn, "Ella")
        XCTAssertEqual(created?.isConfirmed, true)
    }

    func testSkip_writesSkippedAndMovesNothing() async throws {
        let ids = try await anonSegmentIds()
        let intervals = try await verdicts.skip(meetingId: meeting.id, segmentIds: ids)

        XCTAssertEqual(intervals, 2)
        let marks = try await MarkRepository(db: db).verdicts(for: meeting.id)
        XCTAssertTrue(marks.allSatisfy { $0.kind == .skipped && $0.speakerId == nil })
        let owners = Set(try await meetingRepo.segments(for: meeting.id).filter { ids.contains($0.id!) }.map(\.speakerId))
        XCTAssertEqual(owners, [anon.id])
    }

    func testUnknownSegments_throwNoSegments() async throws {
        do {
            _ = try await verdicts.assign(meetingId: meeting.id, segmentIds: [999_999], to: .new(name: "X"))
            XCTFail("ожидалась ошибка")
        } catch SpeakerVerdicts.VerdictError.noSegments {}
    }

    /// 3.3: `update_segment` by segment id finds the meeting and writes a verdict.
    func testAssignBySegmentId_findsTheMeetingAndWritesAVerdict() async throws {
        let alice = Speaker(nameEn: "Alice", isConfirmed: true)
        try await speakerRepo.save(alice)
        let id = try await anonSegmentIds()[0]

        let outcome = try await verdicts.assign(segmentId: id, to: alice.id)

        XCTAssertEqual(outcome.segments, 1)
        let marks = try await MarkRepository(db: db).verdicts(for: meeting.id)
        XCTAssertEqual(marks.map(\.speakerId), [alice.id])
        let linked = Set(try await speakerRepo.speakersForMeeting(meeting.id).map(\.speaker.id))
        XCTAssertTrue(linked.contains(alice.id))
    }

    func testAssignBySegmentId_unknownSpeaker() async throws {
        let id = try await anonSegmentIds()[0]
        do {
            _ = try await verdicts.assign(segmentId: id, to: "ghost")
            XCTFail("ожидалась ошибка")
        } catch SpeakerVerdicts.VerdictError.speakerNotFound {}
    }
}
