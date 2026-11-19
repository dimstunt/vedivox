import XCTest

/// The single exclusion predicate applied at the read surfaces that live in
/// the core target: embedding recalculation and export
/// (transcript-exclusion-marks, group 3).
final class ExclusionReadPathTests: XCTestCase {

    /// Contaminated segments that are marked excluded stop feeding the
    /// canonical: recalculation after the mark lands on the clean voice only.
    func testRecalculationIgnoresExcludedSegments() async throws {
        let db = try makeTestDB()
        let speakerRepo = SpeakerRepository(db: db)
        let meetingRepo = MeetingRepository(db: db)
        let markRepo = MarkRepository(db: db)

        let dim = 256
        var initial = [Float](repeating: 0, count: dim)
        initial[0] = 1.0
        let alice = Speaker(
            id: "alice-id", nameEn: "Alice", isMe: false, isConfirmed: true,
            embedding: Speaker.encodeEmbedding(initial)
        )
        try await speakerRepo.save(alice)

        let meeting = makeMeeting(id: "m-1")
        try await meetingRepo.save(meeting)

        var ownVoice = [Float](repeating: 0, count: dim)
        ownVoice[1] = 1.0
        var foreignVoice = [Float](repeating: 0, count: dim)
        foreignVoice[2] = 1.0

        var segments: [TranscriptSegment] = []
        for i in 0 ..< 10 {
            var seg = makeSegment(
                meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice",
                source: .mic, startTime: Double(i), endTime: Double(i) + 1
            )
            seg.embedding = Speaker.encodeEmbedding(ownVoice)
            segments.append(seg)
        }
        // A contaminated stretch: foreign speech wrongly attributed to Alice.
        for i in 0 ..< 10 {
            var seg = makeSegment(
                meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice",
                source: .mic, startTime: 100 + Double(i), endTime: 100 + Double(i) + 1
            )
            seg.embedding = Speaker.encodeEmbedding(foreignVoice)
            segments.append(seg)
        }
        try await meetingRepo.saveSegments(segments)

        // Mark the contaminated stretch and run the D5 flow.
        try await markRepo.add(MeetingMark(meetingId: meeting.id, startTime: 100, endTime: 111))
        let result = try await markRepo.reprojectAndRecalc(meetingId: meeting.id)
        XCTAssertEqual(result.affectedSpeakerIds, [alice.id])

        let after = try await speakerRepo.find(alice.id)!
        let canon = after.embeddingArray!
        XCTAssertGreaterThan(canon[1], 0.9, "канон следует за чистым голосом")
        XCTAssertLessThan(canon[2], 0.1, "исключённая чужая речь не участвует в пересчёте")
    }

    /// App-side FTS (⌘F meeting search) must not surface excluded speech.
    func testFullTextSearchSkipsExcludedSegments() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let markRepo = MarkRepository(db: db)

        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 0, endTime: 10, text: "обычный разговор"),
            makeSegment(meetingId: meeting.id, source: .mic, startTime: 10, endTime: 20, text: "секретный разговор"),
        ])
        try await markRepo.add(MeetingMark(meetingId: meeting.id, startTime: 10, endTime: 20))
        _ = try await markRepo.reproject(meetingId: meeting.id)

        let visible = try await meetingRepo.meetingIds(matching: "обычный")
        XCTAssertEqual(visible, [meeting.id])
        let excluded = try await meetingRepo.meetingIds(matching: "секретный")
        XCTAssertEqual(excluded, [], "a word only in excluded speech does not find the meeting")
    }

    func testExporterOmitsExcludedSegments() {
        let meeting = makeMeeting(id: "m-2", title: "Экспорт")
        var visible = makeSegment(meetingId: meeting.id, speakerLabel: "Alice", startTime: 0, endTime: 5, text: "остаюсь в экспорте")
        visible.id = 1
        visible.isExcluded = false
        var hidden = makeSegment(meetingId: meeting.id, speakerLabel: "Bob", startTime: 5, endTime: 10, text: "секрет не для экспорта")
        hidden.id = 2
        hidden.isExcluded = true

        let md = TranscriptExporter.markdown(meeting: meeting, segments: [visible, hidden])
        XCTAssertTrue(md.contains("остаюсь в экспорте"))
        XCTAssertFalse(md.contains("секрет"), "исключённый сегмент не должен попадать в экспорт")
        XCTAssertFalse(md.contains("Bob"), "спикер только исключённых сегментов не значится в шапке")
    }

    // MARK: - listen-queue 1.2: verdicts stay out of visibility

    /// A `speaker` verdict laid later over an excluded stretch is not a
    /// visibility mark: reprojection keeps the stretch hidden.
    func testVerdictOverExcludedStretch_keepsItHidden() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let markRepo = MarkRepository(db: db)
        let alice = makeSpeaker(name: "Alice")
        try await SpeakerRepository(db: db).save(alice)
        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, source: .system, startTime: 0, endTime: 10),
        ])

        try await markRepo.add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 10, track: .system))
        try await markRepo.add(MeetingMark(
            meetingId: meeting.id, startTime: 0, endTime: 10, track: .system,
            kind: .speaker, createdAt: Date().addingTimeInterval(60), speakerId: alice.id
        ))
        _ = try await markRepo.reproject(meetingId: meeting.id)

        let segment = try await meetingRepo.segments(for: meeting.id).first!
        XCTAssertTrue(segment.isExcluded, "вердикт не возвращает исключённое в транскрипт")
        let visibility = try await markRepo.marks(for: meeting.id)
        XCTAssertEqual(visibility.map(\.kind), [.excluded])
        let verdicts = try await markRepo.verdicts(for: meeting.id)
        XCTAssertEqual(verdicts.map(\.kind), [.speaker])
    }

    /// The foreign-voice rule subtracts the user's own intervals from what it
    /// hides; a verdict is not one of them, so the auto exclusion still covers it.
    func testForeignVoiceHide_doesNotCarveOutAVerdict() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)
        let markRepo = MarkRepository(db: db)
        let owner = makeSpeaker(name: "Owner", isMe: true)
        let guest = makeSpeaker(name: "Guest")
        try await speakerRepo.save(owner)
        try await speakerRepo.save(guest)
        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: owner.id, source: .mic, startTime: 0, endTime: 10),
            makeSegment(meetingId: meeting.id, speakerId: guest.id, source: .mic, startTime: 10, endTime: 20),
            makeSegment(meetingId: meeting.id, source: .system, startTime: 0, endTime: 20),
        ])
        try await markRepo.add(MeetingMark(
            meetingId: meeting.id, startTime: 10, endTime: 20, track: .mic, kind: .speaker, speakerId: guest.id
        ))

        try await ForeignVoicePolicy(db: db).applyDefault(meetingId: meeting.id, setting: .hideSilently)

        let auto = try await markRepo.marks(for: meeting.id).filter { $0.source == .auto }
        XCTAssertEqual(auto.map { [$0.startTime, $0.endTime ?? -1] }, [[10, 20]],
                       "интервал вердикта не вырезан из автоматической отметки")
    }

    func testAddRefusesAVerdictWithoutSpeaker() async throws {
        let db = try makeTestDB()
        let meeting = makeMeeting()
        try await MeetingRepository(db: db).save(meeting)
        do {
            try await MarkRepository(db: db).add(MeetingMark(meetingId: meeting.id, startTime: 0, endTime: 1, kind: .speaker))
            XCTFail("speaker без speakerId должен отклоняться")
        } catch MarkRepository.MarkError.verdictSpeakerMismatch {}
    }
}
