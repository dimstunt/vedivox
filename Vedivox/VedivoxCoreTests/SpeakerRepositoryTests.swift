import XCTest
import GRDB

final class SpeakerRepositoryTests: XCTestCase {

    private var db: DatabaseManager!
    private var repo: SpeakerRepository!
    private var meetingRepo: MeetingRepository!

    override func setUp() async throws {
        db = try makeTestDB()
        repo = SpeakerRepository(db: db)
        meetingRepo = MeetingRepository(db: db)
    }

    // MARK: - Basic CRUD

    func testSaveSpeaker() async throws {
        let speaker = makeSpeaker(name: "Alice")
        try await repo.save(speaker)

        let fetched = try await repo.find(speaker.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.nameEn, "Alice")
        XCTAssertEqual(fetched?.isMe, false)
    }

    func testFindOrCreateSpeaker_createsNew() async throws {
        let speaker = try await repo.findOrCreateSpeaker(name: "Bob")
        XCTAssertEqual(speaker.nameEn, "Bob")

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
    }

    func testFindOrCreateSpeaker_returnsExisting() async throws {
        let first = try await repo.findOrCreateSpeaker(name: "Bob")
        let second = try await repo.findOrCreateSpeaker(name: "Bob")

        XCTAssertEqual(first.id, second.id)

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1, "Should not create duplicate speaker")
    }

    /// speaker-row-per-mint: автоподпись — слот, не имя. findOrCreateSpeaker
    /// никогда не привязывает её к существующей записи — гард внутри функции
    /// покрывает и UI-пути (rename/reassign), где человек может ввести
    /// «speaker_3» руками.
    func testFindOrCreateSpeaker_autoLabelAlwaysCreatesNew() async throws {
        let first = try await repo.findOrCreateSpeaker(name: "speaker_1")
        let second = try await repo.findOrCreateSpeaker(name: "speaker_1")
        XCTAssertNotEqual(first.id, second.id, "автоподпись не дедупится по имени")

        let all = try await repo.all()
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - Meeting-Speaker Mappings

    func testAssignSpeakerToMeeting() async throws {
        let meeting = makeMeeting()
        let speaker = makeSpeaker(name: "Alice")
        try await meetingRepo.save(meeting)
        try await repo.save(speaker)

        try await repo.assignSpeakerToMeeting(
            meetingId: meeting.id,
            speakerId: speaker.id,
            diarizationLabel: "SPEAKER_00"
        )

        let speakers = try await repo.speakersForMeeting(meeting.id)
        XCTAssertEqual(speakers.count, 1)
        XCTAssertEqual(speakers[0].speaker.id, speaker.id)
        XCTAssertEqual(speakers[0].label, "SPEAKER_00")
    }

    func testAssignSameSpeakerToMultipleMeetings() async throws {
        let m1 = makeMeeting(title: "Meeting 1")
        let m2 = makeMeeting(title: "Meeting 2")
        let speaker = makeSpeaker(name: "Alice")

        try await meetingRepo.save(m1)
        try await meetingRepo.save(m2)
        try await repo.save(speaker)

        try await repo.assignSpeakerToMeeting(meetingId: m1.id, speakerId: speaker.id, diarizationLabel: nil)
        try await repo.assignSpeakerToMeeting(meetingId: m2.id, speakerId: speaker.id, diarizationLabel: nil)

        let meetings = try await repo.meetingsForSpeaker(speaker.id)
        XCTAssertEqual(meetings.count, 2)
    }

    func testSpeakersForMeeting() async throws {
        let m1 = makeMeeting(title: "Meeting 1")
        let m2 = makeMeeting(title: "Meeting 2")
        let alice = makeSpeaker(name: "Alice")
        let bob = makeSpeaker(name: "Bob")

        try await meetingRepo.save(m1)
        try await meetingRepo.save(m2)
        try await repo.save(alice)
        try await repo.save(bob)

        try await repo.assignSpeakerToMeeting(meetingId: m1.id, speakerId: alice.id, diarizationLabel: nil)
        try await repo.assignSpeakerToMeeting(meetingId: m1.id, speakerId: bob.id, diarizationLabel: nil)
        try await repo.assignSpeakerToMeeting(meetingId: m2.id, speakerId: bob.id, diarizationLabel: nil)

        let m1Speakers = try await repo.speakersForMeeting(m1.id)
        XCTAssertEqual(m1Speakers.count, 2)

        let m2Speakers = try await repo.speakersForMeeting(m2.id)
        XCTAssertEqual(m2Speakers.count, 1)
        XCTAssertEqual(m2Speakers[0].speaker.nameEn, "Bob")
    }

    // MARK: - Speaker Info with Meeting Counts

    func testSpeakersWithMeetingCounts() async throws {
        let m1 = makeMeeting(title: "Meeting 1", startTime: Date(timeIntervalSince1970: 1000))
        let m2 = makeMeeting(title: "Meeting 2", startTime: Date(timeIntervalSince1970: 2000))
        let alice = makeSpeaker(name: "Alice")

        try await meetingRepo.save(m1)
        try await meetingRepo.save(m2)
        try await repo.save(alice)

        try await repo.assignSpeakerToMeeting(meetingId: m1.id, speakerId: alice.id, diarizationLabel: nil)
        try await repo.assignSpeakerToMeeting(meetingId: m2.id, speakerId: alice.id, diarizationLabel: nil)

        let infos = try await repo.speakersWithMeetingCounts()
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].meetingCount, 2)
        XCTAssertNotNil(infos[0].lastMeetingDate)
    }

    func testSpeakersWithMeetingCounts_orphanSpeakerHasZero() async throws {
        let speaker = makeSpeaker(name: "Orphan")
        try await repo.save(speaker)

        let infos = try await repo.speakersWithMeetingCounts()
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].meetingCount, 0)
        XCTAssertNil(infos[0].lastMeetingDate)
    }

    // MARK: - Merge Speakers

    func testMergeSpeakers_segmentsReassigned() async throws {
        let meeting = makeMeeting()
        let target = makeSpeaker(name: "Alice")
        let source = makeSpeaker(name: "Speaker 0")

        try await meetingRepo.save(meeting)
        try await repo.save(target)
        try await repo.save(source)

        try await repo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: target.id, diarizationLabel: nil)
        try await repo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: source.id, diarizationLabel: nil)

        let seg = makeSegment(meetingId: meeting.id, speakerId: source.id, speakerLabel: "Speaker 0", text: "Hello")
        try await meetingRepo.saveSegments([seg])

        try await repo.mergeSpeakers(targetId: target.id, sourceIds: [source.id])

        let segments = try await meetingRepo.segments(for: meeting.id)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speakerId, target.id)
        XCTAssertEqual(segments[0].speakerLabel, "Alice")
    }

    /// an unknown source id used to be skipped silently and the
    /// command answered "Merged 2 speaker(s)". Now nothing changes and the
    /// caller learns which id is missing.
    func testMergeSpeakers_unknownSourceChangesNothing() async throws {
        let meeting = makeMeeting()
        let target = makeSpeaker(name: "Alice")
        let source = makeSpeaker(name: "Speaker 0")
        try await meetingRepo.save(meeting)
        try await repo.save(target)
        try await repo.save(source)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: source.id, speakerLabel: "Speaker 0", text: "Hello"),
        ])

        do {
            try await repo.mergeSpeakers(targetId: target.id, sourceIds: [source.id, "no-such-speaker"])
            XCTFail("expected sourceNotFound")
        } catch SpeakerRepository.MergeError.sourceNotFound(let id) {
            XCTAssertEqual(id, "no-such-speaker")
        }

        let source2 = try await repo.find(source.id)
        XCTAssertNotNil(source2, "the known source must survive a refused merge")
        let segments = try await meetingRepo.segments(for: meeting.id)
        XCTAssertEqual(segments.first?.speakerId, source.id)
    }

    /// listen-queue 1.4: a verdict naming the donor points at the target after
    /// the merge instead of vanishing with the donor row.
    func testMergeSpeakers_carriesVerdictsToTarget() async throws {
        let meeting = makeMeeting()
        let target = makeSpeaker(name: "Eleanor")
        let source = makeSpeaker(name: "Ella")
        try await meetingRepo.save(meeting)
        try await repo.save(target)
        try await repo.save(source)
        let marks = MarkRepository(db: db)
        try await marks.add(MeetingMark(
            meetingId: meeting.id, startTime: 0, endTime: 10, track: .system, kind: .speaker, speakerId: source.id
        ))

        try await repo.mergeSpeakers(targetId: target.id, sourceIds: [source.id])

        let verdicts = try await marks.verdicts(for: meeting.id)
        XCTAssertEqual(verdicts.map(\.speakerId), [target.id])
    }

    /// listen-queue 1.4: detaching a meeting drops the record's verdicts there,
    /// and only there.
    func testDetachMeetings_dropsVerdictsOfDetachedMeetingsOnly() async throws {
        let clara = Speaker(nameEn: "Clara", isConfirmed: true)
        try await repo.save(clara)
        let marks = MarkRepository(db: db)
        let gone = makeMeeting()
        let kept = makeMeeting()
        for m in [gone, kept] {
            try await meetingRepo.save(m)
            try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: clara.id, diarizationLabel: nil)
            try await meetingRepo.saveSegments([makeSegment(meetingId: m.id, speakerId: clara.id, speakerLabel: "Clara")])
            try await marks.add(MeetingMark(
                meetingId: m.id, startTime: 0, endTime: 5, track: .mic, kind: .speaker, speakerId: clara.id
            ))
        }

        try await repo.detachMeetings(speakerId: clara.id, meetingIds: [gone.id])

        let goneVerdicts = try await marks.verdicts(for: gone.id)
        let keptVerdicts = try await marks.verdicts(for: kept.id)
        XCTAssertTrue(goneVerdicts.isEmpty)
        XCTAssertEqual(keptVerdicts.map(\.speakerId), [clara.id])
    }

    func testMergeSpeakers_meetingSpeakersConsolidated() async throws {
        let meeting = makeMeeting()
        let target = makeSpeaker(name: "Alice")
        let source = makeSpeaker(name: "Speaker 0")

        try await meetingRepo.save(meeting)
        try await repo.save(target)
        try await repo.save(source)

        try await repo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: target.id, diarizationLabel: "SPEAKER_00")
        try await repo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: source.id, diarizationLabel: "SPEAKER_01")

        try await repo.mergeSpeakers(targetId: target.id, sourceIds: [source.id])

        let speakers = try await repo.speakersForMeeting(meeting.id)
        XCTAssertEqual(speakers.count, 1)
        XCTAssertEqual(speakers[0].speaker.id, target.id)
    }

    func testMergeSpeakers_sourceDeleted() async throws {
        let meeting = makeMeeting()
        let target = makeSpeaker(name: "Alice")
        let source = makeSpeaker(name: "Speaker 0")

        try await meetingRepo.save(meeting)
        try await repo.save(target)
        try await repo.save(source)
        try await repo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: target.id, diarizationLabel: nil)
        try await repo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: source.id, diarizationLabel: nil)

        try await repo.mergeSpeakers(targetId: target.id, sourceIds: [source.id])

        let deleted = try await repo.find(source.id)
        XCTAssertNil(deleted, "Source speaker should be deleted after merge")
    }

    /// Merging the owner's record into a duplicate ("keep the other one" in
    /// the similar-voices banner) deleted the only isMe row: the mic track was
    /// no longer linked to the owner and the foreign-voice rule switched off.
    func testMergeSpeakers_ownerMarkMovesToTheTarget() async throws {
        let target = makeSpeaker(name: "Clara")
        let source = makeSpeaker(name: "Me", isMe: true)
        try await repo.save(target)
        try await repo.save(source)

        try await repo.mergeSpeakers(targetId: target.id, sourceIds: [source.id])

        let me = try await repo.findMe()
        XCTAssertEqual(me?.id, target.id)
        XCTAssertEqual(me?.isConfirmed, true)
    }

    func testMergeSpeakers_duplicateMeetingHandled() async throws {
        let meeting = makeMeeting()
        let target = makeSpeaker(name: "Alice")
        let source = makeSpeaker(name: "Speaker 0")

        try await meetingRepo.save(meeting)
        try await repo.save(target)
        try await repo.save(source)

        // Both speakers in the same meeting — merge should not crash
        try await repo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: target.id, diarizationLabel: "SPEAKER_00")
        try await repo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: source.id, diarizationLabel: "SPEAKER_01")

        try await repo.mergeSpeakers(targetId: target.id, sourceIds: [source.id])

        let speakers = try await repo.speakersForMeeting(meeting.id)
        XCTAssertEqual(speakers.count, 1)
    }

    // MARK: - Merge recalculates target canonical (apply-anon-identification)

    /// «Слепок следует за составом голосов»: merged-in meeting voices must
    /// show up in the target's canonical right away.
    func testMergeSpeakers_recalculatesTargetCanonical() async throws {
        let dim = 256
        let axis0: [Float] = { var v = [Float](repeating: 0, count: dim)
        v[0] = 1
        return v }()
        let axis1: [Float] = { var v = [Float](repeating: 0, count: dim)
        v[1] = 1
        return v }()

        let target = Speaker(nameEn: "Target", isConfirmed: true,
                             embedding: Speaker.encodeEmbedding(axis1))
        try await repo.save(target)
        let source = makeSpeaker(name: "speaker_1")
        try await repo.save(source)

        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        var segments: [TranscriptSegment] = []
        for i in 0 ..< 10 {
            var seg = makeSegment(
                meetingId: meeting.id, speakerId: source.id, speakerLabel: "speaker_1",
                startTime: Double(i) * 2, endTime: Double(i) * 2 + 2
            )
            seg.embedding = Speaker.encodeEmbedding(axis0)
            segments.append(seg)
        }
        try await meetingRepo.saveSegments(segments)

        try await repo.mergeSpeakers(targetId: target.id, sourceIds: [source.id])

        let canon = try await repo.find(target.id)!.embeddingArray!
        XCTAssertGreaterThan(canon[0], 0.9, "canonical must follow the merged-in voices")
    }

    // MARK: - Delete speaker

    /// Подтверждённого спикера можно удалить: реплики уходят к анониму своей
    /// встречи, вердикты и исполнитель задач сняты, записи больше нет.
    func testDeleteSpeaker_linesGoAnonymousVerdictsAndRowGone() async throws {
        let clara = Speaker(nameEn: "Clara", isConfirmed: true)
        let bob = makeSpeaker(name: "Bob")
        try await repo.save(clara)
        try await repo.save(bob)
        let marks = MarkRepository(db: db)
        let m1 = makeMeeting()
        let m2 = makeMeeting()
        for m in [m1, m2] {
            try await meetingRepo.save(m)
            try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: clara.id, diarizationLabel: nil)
            try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: bob.id, diarizationLabel: nil)
            try await meetingRepo.saveSegments([
                makeSegment(meetingId: m.id, speakerId: clara.id, speakerLabel: "Clara", text: "clara line"),
                makeSegment(meetingId: m.id, speakerId: bob.id, speakerLabel: "Bob", startTime: 10, endTime: 12),
            ])
            try await marks.add(MeetingMark(
                meetingId: m.id, startTime: 0, endTime: 5, track: .mic, kind: .speaker, speakerId: clara.id
            ))
        }

        let touched = try await repo.deleteSpeaker(clara.id)

        XCTAssertEqual(touched, 2)
        let gone = try await repo.find(clara.id)
        XCTAssertNil(gone)
        for m in [m1, m2] {
            let verdicts = try await marks.verdicts(for: m.id)
            XCTAssertTrue(verdicts.isEmpty)
            let speakers = try await repo.speakersForMeeting(m.id)
            XCTAssertTrue(speakers.contains { $0.speaker.id == bob.id }, "other speaker untouched")
            let anon = speakers.first { $0.speaker.id != bob.id }?.speaker
            XCTAssertNotNil(anon)
            XCTAssertTrue(anon.map { Speaker.isAutoLabel($0.nameEn) && !$0.isConfirmed } ?? false)
            let label: String? = try await db.reader.read { db in
                try String.fetchOne(db, sql: "SELECT speakerLabel FROM transcript_segments WHERE meetingId = ? AND text = 'clara line'", arguments: [m.id])
            }
            XCTAssertEqual(label, anon?.nameEn)
        }
    }

    /// Владельца удалить нельзя: на нём держится атрибуция микрофона.
    func testDeleteSpeaker_refusesOwnerAndUnknown() async throws {
        let me = Speaker(nameEn: "Me", isMe: true, isConfirmed: true)
        try await repo.save(me)

        do {
            try await repo.deleteSpeaker(me.id)
            XCTFail("owner must not be deleted")
        } catch SpeakerRepository.DeleteError.isOwner {}
        do {
            try await repo.deleteSpeaker("missing")
            XCTFail("unknown id must throw")
        } catch SpeakerRepository.DeleteError.notFound {}
        let kept = try await repo.find(me.id)
        XCTAssertNotNil(kept)
    }

    // MARK: - Detach meetings (apply-anon-identification)

    /// «Снятие встреч с записи спикера»: сегменты уходят к новой анонимной
    /// записи своей встречи, текст не тронут, третья встреча остаётся.
    func testDetachMeetings_movesSegmentsToFreshAnonRecords() async throws {
        let clara = Speaker(nameEn: "Clara", isConfirmed: true)
        try await repo.save(clara)

        let m1 = makeMeeting()
        let m2 = makeMeeting()
        let kept = makeMeeting()
        for m in [m1, m2, kept] {
            try await meetingRepo.save(m)
            try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: clara.id, diarizationLabel: "SPEAKER_00")
            try await meetingRepo.saveSegments([
                makeSegment(meetingId: m.id, speakerId: clara.id, speakerLabel: "Clara", text: "hello from \(m.id)"),
            ])
        }

        try await repo.detachMeetings(speakerId: clara.id, meetingIds: [m1.id, m2.id])

        for m in [m1, m2] {
            let rows: [(String, String, String)] = try await db.reader.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT ts.speakerId, ts.speakerLabel, ts.text FROM transcript_segments ts
                    WHERE ts.meetingId = ?
                    """, arguments: [m.id]).map { ($0["speakerId"], $0["speakerLabel"], $0["text"]) }
            }
            XCTAssertEqual(rows.count, 1)
            XCTAssertNotEqual(rows[0].0, clara.id, "segment must leave Clara")
            XCTAssertEqual(rows[0].1, "speaker_1", "fresh per-meeting auto label")
            XCTAssertEqual(rows[0].2, "hello from \(m.id)", "text untouched")

            let speakers = try await repo.speakersForMeeting(m.id)
            XCTAssertEqual(speakers.map(\.speaker.id), [rows[0].0], "association moved to the fresh record")
        }

        // Two different fresh records, not one shared.
        let fresh1 = try await repo.speakersForMeeting(m1.id)[0].speaker
        let fresh2 = try await repo.speakersForMeeting(m2.id)[0].speaker
        XCTAssertNotEqual(fresh1.id, fresh2.id)
        XCTAssertFalse(fresh1.isConfirmed)

        // The kept meeting still belongs to Clara.
        let keptSpeakers = try await repo.speakersForMeeting(kept.id)
        XCTAssertEqual(keptSpeakers.map(\.speaker.id), [clara.id])
    }

    /// «Автоподпись не конфликтует»: номер идёт за наибольшим занятым в встрече.
    func testDetachMeetings_autoLabelSkipsTaken() async throws {
        let clara = Speaker(nameEn: "Clara", isConfirmed: true)
        let other = makeSpeaker(name: "speaker_4")
        try await repo.save(clara)
        try await repo.save(other)

        let m = makeMeeting()
        try await meetingRepo.save(m)
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: clara.id, diarizationLabel: "SPEAKER_00")
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: other.id, diarizationLabel: "SPEAKER_01")
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: m.id, speakerId: clara.id, speakerLabel: "Clara"),
            makeSegment(meetingId: m.id, speakerId: other.id, speakerLabel: "speaker_4", startTime: 10, endTime: 12),
        ])

        try await repo.detachMeetings(speakerId: clara.id, meetingIds: [m.id])

        let label: String? = try await db.reader.read { db in
            try String.fetchOne(db, sql: """
                SELECT speakerLabel FROM transcript_segments
                WHERE meetingId = ? AND speakerId != ?
                """, arguments: [m.id, other.id])
        }
        XCTAssertEqual(label, "speaker_5")
    }

    /// «Осиротевшее пространство очищено»: v2 остался без голосов — канон v2
    /// пуст; v1 пересчитан по оставшимся голосам.
    func testDetachMeetings_orphanedSpaceCleared() async throws {
        let dim = 256
        let axis0: [Float] = { var v = [Float](repeating: 0, count: dim)
        v[0] = 1
        return v }()
        let axis1: [Float] = { var v = [Float](repeating: 0, count: dim)
        v[1] = 1
        return v }()

        let clara = Speaker(nameEn: "Clara", isConfirmed: true,
                            embedding: Speaker.encodeEmbedding(axis0))
        try await repo.save(clara)
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE speakers SET embeddingV2 = ? WHERE id = ?",
                           arguments: [Speaker.encodeEmbedding(axis0), clara.id])
        }

        var v2meeting = makeMeeting()
        v2meeting.diarizer = "offline"
        let v1meeting = makeMeeting()
        try await meetingRepo.save(v2meeting)
        try await meetingRepo.save(v1meeting)
        for (m, axis) in [(v2meeting, axis0), (v1meeting, axis1)] {
            try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: clara.id, diarizationLabel: "SPEAKER_00")
            var segments: [TranscriptSegment] = []
            for i in 0 ..< 10 {
                var seg = makeSegment(meetingId: m.id, speakerId: clara.id, speakerLabel: "Clara",
                                      startTime: Double(i) * 2, endTime: Double(i) * 2 + 2)
                seg.embedding = Speaker.encodeEmbedding(axis)
                segments.append(seg)
            }
            try await meetingRepo.saveSegments(segments)
        }

        try await repo.detachMeetings(speakerId: clara.id, meetingIds: [v2meeting.id])

        let (v1canon, v2canon): (Data?, Data?) = try await db.reader.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT embedding, embeddingV2 FROM speakers WHERE id = ?",
                                       arguments: [clara.id])!
            return (row["embedding"], row["embeddingV2"])
        }
        XCTAssertNil(v2canon, "orphaned v2 canonical must be cleared")
        let v1 = Speaker.decodeEmbedding(v1canon!)
        XCTAssertGreaterThan(v1[1], 0.9, "v1 canonical recalculated from the remaining v1 voices")
    }

    // MARK: - Mark as Me

    func testMarkAsMe_exclusivity() async throws {
        let alice = makeSpeaker(name: "Alice", isMe: true)
        let bob = makeSpeaker(name: "Bob")

        try await repo.save(alice)
        try await repo.save(bob)

        try await repo.markAsMe(bob.id)

        let fetchedAlice = try await repo.find(alice.id)
        let fetchedBob = try await repo.find(bob.id)
        XCTAssertEqual(fetchedAlice?.isMe, false, "Alice should no longer be isMe")
        XCTAssertEqual(fetchedBob?.isMe, true, "Bob should now be isMe")
    }

    // MARK: - Profile

    func testUpdateProfile() async throws {
        let speaker = makeSpeaker(name: "Speaker 0")
        try await repo.save(speaker)

        try await repo.updateProfile(speaker.id, nameEn: "Alice", nameRu: "Алиса", nickname: "alice")

        let fetched = try await repo.find(speaker.id)
        XCTAssertEqual(fetched?.nameEn, "Alice")
        XCTAssertEqual(fetched?.nickname, "alice")
        XCTAssertEqual(fetched?.nameRu, "Алиса")
    }

    func testUpdateSegmentLabelsForSpeaker() async throws {
        let meeting = makeMeeting()
        let speaker = makeSpeaker(name: "Speaker 0")
        try await meetingRepo.save(meeting)
        try await repo.save(speaker)

        let seg1 = makeSegment(meetingId: meeting.id, speakerId: speaker.id, speakerLabel: "Speaker 0", startTime: 0, endTime: 5, text: "A")
        let seg2 = makeSegment(meetingId: meeting.id, speakerId: speaker.id, speakerLabel: "Speaker 0", startTime: 5, endTime: 10, text: "B")
        try await meetingRepo.saveSegments([seg1, seg2])

        try await repo.updateSegmentLabelsForSpeaker(speaker.id, newLabel: "Alice")

        let segments = try await meetingRepo.segments(for: meeting.id)
        XCTAssertTrue(segments.allSatisfy { $0.speakerLabel == "Alice" })
    }

    func testRename() async throws {
        let speaker = makeSpeaker(name: "Speaker 0")
        try await repo.save(speaker)

        try await repo.rename(speaker.id, name: "Alice")

        let fetched = try await repo.find(speaker.id)
        XCTAssertEqual(fetched?.nameEn, "Alice")
    }

    // MARK: - FK Safety

    func testAssignSpeakerToMeeting_deletedSpeaker_skips() async throws {
        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)

        let speaker = makeSpeaker(name: "Temp")
        try await repo.save(speaker)

        // Delete the speaker before assigning (simulates concurrent merge)
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [speaker.id])
        }

        // Should not throw — silently skips the deleted speaker
        try await repo.assignSpeakerToMeeting(
            meetingId: meeting.id,
            speakerId: speaker.id,
            diarizationLabel: "SPEAKER_00"
        )

        let speakers = try await repo.speakersForMeeting(meeting.id)
        XCTAssertEqual(speakers.count, 0, "No link should be created for deleted speaker")
    }

    func testSpeakersWithEmbeddings_excludesSpeakersWithoutEmbedding() async throws {
        let fakeEmbedding = Speaker.encodeEmbedding([Float](repeating: 0.1, count: 256))
        let withEmb = Speaker(nameEn: "Alice", isConfirmed: true, embedding: fakeEmbedding)
        let noEmb = makeSpeaker(name: "Bob") // no embedding
        try await repo.save(withEmb)
        try await repo.save(noEmb)
        try await repo.confirmSpeaker(noEmb.id)

        let result = try await repo.speakersWithEmbeddings(space: .v1)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, withEmb.id)
    }

    // MARK: - One transaction per change

    /// A speaker with one line in a meeting of its own.
    private func speakerWithALine(_ name: String) async throws -> (speaker: Speaker, meeting: Meeting) {
        let speaker = makeSpeaker(name: name)
        let meeting = makeMeeting()
        try await repo.save(speaker)
        try await meetingRepo.save(meeting)
        try await repo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: speaker.id, diarizationLabel: name)
        try await meetingRepo.saveSegments([makeSegment(meetingId: meeting.id, speakerId: speaker.id, speakerLabel: name)])
        return (speaker, meeting)
    }

    /// From here on a statement of this kind aborts, the way a full disk or a broken row would.
    private func failWrites(_ event: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER injected BEFORE \(event) BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
    }

    /// Speakers, links and who holds which line, as comparable rows.
    private func identityRows() async throws -> [String] {
        try await db.reader.read { db in
            try String.fetchAll(db, sql: """
                SELECT id || '|' || nameEn || '|' || isConfirmed FROM speakers
                UNION ALL SELECT meetingId || '>' || speakerId FROM meeting_speakers
                UNION ALL SELECT id || ':' || IFNULL(speakerId, '') || ':' || IFNULL(speakerLabel, '') FROM transcript_segments
                ORDER BY 1
                """)
        }
    }

    /// A profile save was two writes: a failure between them left the new name
    /// on the record and the old one on its lines.
    func testProfileSaveRelabelsTheLinesInTheSameWrite() async throws {
        let (bob, meeting) = try await speakerWithALine("Bob")

        try await repo.updateProfile(bob.id, nameEn: "Robert", nameRu: "Роберт", nickname: nil)
        let label = try await meetingRepo.segments(for: meeting.id).first?.speakerLabel
        XCTAssertEqual(label, "Роберт", "the lines carry the display name")

        let before = try await identityRows()
        try await failWrites("UPDATE OF speakerLabel ON transcript_segments")
        do {
            try await repo.updateProfile(bob.id, nameEn: "Bobby", nameRu: nil, nickname: nil)
            XCTFail("the lines were not part of the save")
        } catch {}
        let after = try await identityRows()
        XCTAssertEqual(after, before, "a save that cannot relabel the lines changes nothing")
    }

    /// The merge screens confirmed the target in a second write: when it failed
    /// the merge stayed, reported as failed and without an undo.
    func testMergeConfirmsItsTargetInTheSameWrite() async throws {
        let (alice, _) = try await speakerWithALine("Alice")
        let (bob, _) = try await speakerWithALine("Bob")
        let before = try await identityRows()
        try await failWrites("UPDATE OF isConfirmed ON speakers")

        do {
            try await repo.mergeSpeakers(targetId: alice.id, sourceIds: [bob.id], confirmTarget: true)
            XCTFail("the confirmation was not part of the merge")
        } catch {}

        let after = try await identityRows()
        XCTAssertEqual(after, before, "a merge that cannot confirm its target changes nothing")
    }

    func testNamingASpeakerInAMeeting() async throws {
        let (anon, meeting) = try await speakerWithALine("speaker_1")

        try await repo.nameSpeakerInMeeting(
            meetingId: meeting.id, oldLabel: "speaker_1", newName: "Carol", fromSpeakerId: anon.id
        )

        let linked = try await repo.speakersForMeeting(meeting.id)
        XCTAssertEqual(linked.map(\.speaker.nameEn), ["Carol"])
        XCTAssertEqual(linked.first?.speaker.isConfirmed, true)
        XCTAssertEqual(linked.first?.label, "speaker_1", "the link keeps the diarization label")
        let line = try await meetingRepo.segments(for: meeting.id).first
        XCTAssertEqual(line?.speakerId, linked.first?.speaker.id)
        XCTAssertEqual(line?.speakerLabel, "Carol")
        let gone = try await repo.find(anon.id)
        XCTAssertNil(gone, "the anonymous record left without lines goes")
    }

    /// Rename Speaker in a transcript was five writes: a failure on the lines
    /// left a new confirmed record linked to the meeting, and no undo.
    func testNamingASpeakerInAMeetingIsAllOrNothing() async throws {
        let (anon, meeting) = try await speakerWithALine("speaker_1")
        let before = try await identityRows()
        try await failWrites("UPDATE OF speakerId ON transcript_segments")

        do {
            try await repo.nameSpeakerInMeeting(
                meetingId: meeting.id, oldLabel: "speaker_1", newName: "Carol", fromSpeakerId: anon.id
            )
            XCTFail("the lines were not moved, so the call must fail")
        } catch {}

        let after = try await identityRows()
        XCTAssertEqual(after, before, "a rename that cannot move the lines changes nothing")
    }
}
