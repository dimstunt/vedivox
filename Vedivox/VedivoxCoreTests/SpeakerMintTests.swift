import XCTest

/// speaker-row-per-mint: every unmatched voice becomes its OWN speaker row.
/// Auto `speaker_N` labels are per-meeting slot names and must never bind to
/// an existing row by name — that is how one speaker_1 row collected 72
/// meetings of different people.
final class SpeakerMintTests: XCTestCase {

    /// Два незнакомца в двух встречах, оба подписаны speaker_1 → две записи,
    /// у каждой ровно одна встреча (spec: speaker-identity).
    func testAutoLabelMintsSeparateRowPerMeeting() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let repo = SpeakerRepository(db: db)
        let pipeline = TranscriptionPipeline(db: db)

        for title in ["A", "B"] {
            let meeting = makeMeeting(title: title)
            try await meetingRepo.save(meeting)
            try await meetingRepo.saveSegments([
                makeSegment(meetingId: meeting.id, speakerLabel: "speaker_1",
                            source: .system, startTime: 0, endTime: 30),
            ])
            let segments = try await meetingRepo.segments(for: meeting.id)
            try await pipeline.createSpeakersFromDiarization(
                segments, meetingId: meeting.id, speakerEmbeddings: [:], labelToDbId: [:]
            )
        }

        let all = try await repo.all()
        let rows = all.filter { $0.nameEn == "speaker_1" }
        XCTAssertEqual(rows.count, 2, "каждый минт — своя запись")
        for row in rows {
            let meetings = try await repo.meetingsForSpeaker(row.id)
            XCTAssertEqual(meetings.count, 1, "у автозаписи ровно одна встреча")
        }
    }

    /// Человеческое имя по-прежнему дедупится по имени: вторая встреча с
    /// подписью «Клара» не создаёт вторую запись.
    func testHumanLabelStillDeduplicatesByName() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let repo = SpeakerRepository(db: db)
        let pipeline = TranscriptionPipeline(db: db)

        for title in ["A", "B"] {
            let meeting = makeMeeting(title: title)
            try await meetingRepo.save(meeting)
            try await meetingRepo.saveSegments([
                makeSegment(meetingId: meeting.id, speakerLabel: "Клара",
                            source: .system, startTime: 0, endTime: 30),
            ])
            let segments = try await meetingRepo.segments(for: meeting.id)
            try await pipeline.createSpeakersFromDiarization(
                segments, meetingId: meeting.id, speakerEmbeddings: [:], labelToDbId: [:]
            )
        }

        let all = try await repo.all()
        let rows = all.filter { $0.nameEn == "Клара" }
        XCTAssertEqual(rows.count, 1, "человеческое имя не плодит записей")
        let meetings = try await repo.meetingsForSpeaker(rows[0].id)
        XCTAssertEqual(meetings.count, 2)
    }

    /// Проброс reservedLabels через applyMatcherResults: занятые подписи
    /// двигают нумерацию минта. Сам расчёт покрыт ClusterLabelerTests;
    /// mic-путь целиком headless не гоняется (нужно живое аудио).
    func testApplyMatcherResultsRespectsReservedLabels() async throws {
        let db = try makeTestDB()
        let pipeline = TranscriptionPipeline(db: db)

        let segs = [DiarizationService.DiarizationSegment(
            start: 0, end: 40, speaker: "1", embedding: [0, 0, 0, 1]
        )]
        let out = await pipeline.applyMatcherResults(
            segs,
            speakerEmbeddings: ["1": [0, 0, 0, 1]],
            matchResults: ["1": .unmatched(reason: .emptyPool)],
            reservedLabels: ["speaker_1", "speaker_2", "me"]
        )
        XCTAssertEqual(Set(out.segments.map(\.speaker)), ["speaker_3"],
                       "минт продолжает нумерацию после занятых подписей")
    }
}
