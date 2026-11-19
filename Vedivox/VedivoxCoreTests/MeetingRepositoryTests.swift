import XCTest
import GRDB

final class MeetingRepositoryTests: XCTestCase {

    private var db: DatabaseManager!
    private var repo: MeetingRepository!
    private var speakerRepo: SpeakerRepository!
    private var tagRepo: TagRepository!

    override func setUp() async throws {
        db = try makeTestDB()
        repo = MeetingRepository(db: db)
        speakerRepo = SpeakerRepository(db: db)
        tagRepo = TagRepository(db: db)
    }

    // MARK: - Trim keeps speaker links true

    /// Trim deleted the lines outside the kept range but left their speakers
    /// linked: someone who spoke only in the cut-off part stayed on the meeting.
    func testTrim_unlinksSpeakerWhoseLinesWereAllCutOff() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-trim-speakers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        var meeting = makeMeeting()
        meeting.durationSeconds = 100
        try await repo.save(meeting)
        let alice = makeSpeaker(name: "Alice"), bob = makeSpeaker(name: "Bob")
        for s in [alice, bob] {
            try await speakerRepo.save(s)
            try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: s.id, diarizationLabel: s.nameEn)
        }
        try await repo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: bob.id, speakerLabel: "Bob", startTime: 0, endTime: 10),
            makeSegment(meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice", startTime: 30, endTime: 50),
            makeSegment(meetingId: meeting.id, speakerId: bob.id, speakerLabel: "Bob", startTime: 85, endTime: 95),
        ])

        try await repo.trimMeeting(meeting.id, keepFrom: 20, keepTo: 80, audioRoot: tempRoot)

        let linked = try await speakerRepo.speakersForMeeting(meeting.id).map { $0.speaker.id }
        XCTAssertEqual(linked, [alice.id], "Bob spoke only before and after the kept range")
    }

    // MARK: - Split keeps speaker links true

    /// The first half used to keep every speaker of the long recording,
    /// including those whose segments all moved to the second half.
    func testSplitAndUndo_speakerLinksFollowSegments() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-split-speakers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var meeting = makeMeeting()
        meeting.durationSeconds = 100
        try await repo.save(meeting)
        for id in ["early", "late", "both"] {
            try await speakerRepo.save(makeSpeaker(id: id, name: id))
        }
        try await repo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: "early", source: .system, startTime: 0, endTime: 20),
            makeSegment(meetingId: meeting.id, speakerId: "both", source: .system, startTime: 20, endTime: 40),
            makeSegment(meetingId: meeting.id, speakerId: "both", source: .system, startTime: 60, endTime: 80),
            makeSegment(meetingId: meeting.id, speakerId: "late", source: .system, startTime: 80, endTime: 100),
        ])
        for id in ["early", "late", "both"] {
            try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: id, diarizationLabel: nil)
        }

        func linked(_ meetingId: String) async throws -> Set<String> {
            try await db.writer.read { db in
                try Set(String.fetchAll(db, sql: "SELECT speakerId FROM meeting_speakers WHERE meetingId = ?",
                                        arguments: [meetingId]))
            }
        }

        let (m1, m2) = try await repo.splitMeeting(meeting.id, atTime: 50, audioRoot: tempRoot)
        let first = try await linked(m1.id)
        let second = try await linked(m2.id)
        XCTAssertEqual(first, ["early", "both"], "в первой половине нет фантома late")
        XCTAssertEqual(second, ["late", "both"])

        try await repo.undoSplit(meeting.id, audioRoot: tempRoot)
        let restored = try await linked(meeting.id)
        XCTAssertEqual(restored, ["early", "late", "both"], "отмена разреза возвращает ушедших спикеров")
    }

    // MARK: - Basic CRUD

    func testSaveMeeting() async throws {
        let meeting = makeMeeting(title: "Standup")
        try await repo.save(meeting)

        let fetched = try await repo.find(meeting.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Standup")
        XCTAssertEqual(fetched?.status, .done)
    }

    /// The pipeline compresses audio for a long while after it read the
    /// meeting; saving that snapshot back undid a rename made in between.
    func testUpdateAudioPathsLeavesTheRestOfTheRowAlone() async throws {
        var meeting = makeMeeting(title: "Old title")
        meeting.micAudioPath = "/audio/mic.wav"
        meeting.systemAudioPath = "/audio/system.wav"
        try await repo.save(meeting)
        var renamed = meeting
        renamed.title = "New title"
        try await repo.save(renamed)

        try await repo.updateAudioPaths(meeting.id, mic: "/audio/mic.m4a")

        let fetched = try await repo.find(meeting.id)
        XCTAssertEqual(fetched?.title, "New title")
        XCTAssertEqual(fetched?.micAudioPath, "/audio/mic.m4a")
        XCTAssertEqual(fetched?.systemAudioPath, "/audio/system.wav")
    }

    // MARK: - Delete Batch

    func testDeleteBatch_removesAllRelatedData() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)

        // Add segments
        let seg = makeSegment(meetingId: meeting.id, text: "Hello")
        try await repo.saveSegments([seg])

        // Add speaker mapping
        let speaker = makeSpeaker(name: "Alice")
        try await speakerRepo.save(speaker)
        try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: speaker.id, diarizationLabel: nil)

        // Add tag
        let tag = Tag(name: "important")
        try await tagRepo.save(tag)
        try await tagRepo.addTagToMeeting(tagId: tag.id, meetingId: meeting.id)

        // Delete
        try await repo.deleteBatch([meeting.id])

        // Verify all related data is gone
        let fetchedMeeting = try await repo.find(meeting.id)
        XCTAssertNil(fetchedMeeting)

        let segments = try await repo.segments(for: meeting.id)
        XCTAssertTrue(segments.isEmpty)

        let speakers = try await speakerRepo.speakersForMeeting(meeting.id)
        XCTAssertTrue(speakers.isEmpty)

        let tags = try await tagRepo.tagsForMeeting(meeting.id)
        XCTAssertTrue(tags.isEmpty)
    }

    /// the meeting's unconfirmed speakers go with it; a confirmed one,
    /// the owner and anyone heard in another meeting stay.
    func testDeleteBatch_unconfirmedSpeakersGoWithTheMeeting() async throws {
        let meeting = makeMeeting(), other = makeMeeting(), alsoDeleted = makeMeeting()
        for m in [meeting, other, alsoDeleted] { try await repo.save(m) }

        let temp = makeSpeaker(name: "speaker_1"), me = makeSpeaker(name: "Me", isMe: true)
        let shared = makeSpeaker(name: "speaker_2"), lineElsewhere = makeSpeaker(name: "speaker_3")
        let bothDeleted = makeSpeaker(name: "speaker_4")
        var named = makeSpeaker(name: "Alice")
        named.isConfirmed = true
        for s in [temp, me, shared, lineElsewhere, bothDeleted, named] {
            try await speakerRepo.save(s)
            try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: s.id, diarizationLabel: nil)
        }
        try await speakerRepo.assignSpeakerToMeeting(meetingId: other.id, speakerId: shared.id, diarizationLabel: nil)
        try await speakerRepo.assignSpeakerToMeeting(meetingId: alsoDeleted.id, speakerId: bothDeleted.id, diarizationLabel: nil)
        // A line without a link (a legacy gap): the speaker row is still in use there.
        try await repo.saveSegments([makeSegment(meetingId: other.id, speakerId: lineElsewhere.id, speakerLabel: "speaker_3")])

        try await repo.deleteBatch([meeting.id, alsoDeleted.id])

        for gone in [temp, bothDeleted] {
            let fetched = try await speakerRepo.find(gone.id)
            XCTAssertNil(fetched, "\(gone.nameEn) was only in the deleted meetings")
        }
        for kept in [me, shared, lineElsewhere, named] {
            let fetched = try await speakerRepo.find(kept.id)
            XCTAssertNotNil(fetched, "\(kept.nameEn) must survive")
        }
    }

    func testDeleteBatch_emptySetIsNoop() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)

        try await repo.deleteBatch([])

        let kept = try await repo.find(meeting.id)
        XCTAssertNotNil(kept, "an empty selection must delete nothing")
    }

    /// Exclusion marks hang on the meeting by a foreign key with ON DELETE
    /// CASCADE; deleteBatch does not remove them by hand.
    func testDeleteBatch_cascadesToMarks() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)
        try await db.writer.write {
            try $0.execute(sql: "INSERT INTO meeting_marks (meetingId, startTime, endTime) VALUES (?, 1, 2)", arguments: [meeting.id])
        }
        let before = try await markCount(meeting.id)
        XCTAssertEqual(before, 1)

        try await repo.deleteBatch([meeting.id])

        let after = try await markCount(meeting.id)
        XCTAssertEqual(after, 0, "a deleted meeting must not leave its marks behind")
    }

    private func markCount(_ meetingId: String) async throws -> Int? {
        try await db.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting_marks WHERE meetingId = ?", arguments: [meetingId])
        }
    }

    // MARK: - Full-text index

    /// transcript_fts is kept in step by triggers: an edited line is found by
    /// its new words only, a deleted meeting by none.
    func testSearchIndexFollowsSegmentUpdateAndDelete() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)
        try await repo.saveSegments([makeSegment(meetingId: meeting.id, text: "quokka")])
        let first = try await repo.meetingIds(matching: "quokka")
        XCTAssertEqual(first, [meeting.id])

        try await db.writer.write {
            try $0.execute(sql: "UPDATE transcript_segments SET text = 'axolotl' WHERE meetingId = ?", arguments: [meeting.id])
        }
        let oldWord = try await repo.meetingIds(matching: "quokka")
        let newWord = try await repo.meetingIds(matching: "axolotl")
        XCTAssertEqual(oldWord, [], "the index must forget the replaced text")
        XCTAssertEqual(newWord, [meeting.id], "the index must learn the new text")

        try await repo.deleteBatch([meeting.id])
        let deleted = try await repo.meetingIds(matching: "axolotl")
        XCTAssertEqual(deleted, [], "a deleted meeting must leave the index")
    }

    // MARK: - Segments

    func testSaveSegments() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)

        let seg1 = makeSegment(meetingId: meeting.id, startTime: 10, endTime: 15, text: "Second")
        let seg2 = makeSegment(meetingId: meeting.id, startTime: 0, endTime: 5, text: "First")
        try await repo.saveSegments([seg1, seg2])

        let segments = try await repo.segments(for: meeting.id)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "First", "Should be ordered by startTime")
        XCTAssertEqual(segments[1].text, "Second")
    }

    func testUpdateSegmentText_setsOriginalText() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)

        let seg = makeSegment(meetingId: meeting.id, text: "Original text")
        try await repo.saveSegments([seg])

        let segments = try await repo.segments(for: meeting.id)
        let segId = segments[0].id!

        try await repo.updateSegmentText(id: segId, text: "Edited text")

        let updated = try await repo.segments(for: meeting.id)
        XCTAssertEqual(updated[0].text, "Edited text")
        XCTAssertEqual(updated[0].originalText, "Original text")
        XCTAssertTrue(updated[0].isEdited)
    }

    func testUpdateSegmentText_preservesExistingOriginal() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)

        let seg = makeSegment(meetingId: meeting.id, text: "V1")
        try await repo.saveSegments([seg])

        let segId = try await repo.segments(for: meeting.id)[0].id!

        try await repo.updateSegmentText(id: segId, text: "V2")
        try await repo.updateSegmentText(id: segId, text: "V3")

        let updated = try await repo.segments(for: meeting.id)
        XCTAssertEqual(updated[0].text, "V3")
        XCTAssertEqual(updated[0].originalText, "V1", "Original should be preserved from first edit")
    }

    func testUpdateSegmentSpeaker() async throws {
        let meeting = makeMeeting()
        let alice = makeSpeaker(name: "Alice")
        let bob = makeSpeaker(name: "Bob")
        try await repo.save(meeting)
        try await speakerRepo.save(alice)
        try await speakerRepo.save(bob)

        let seg = makeSegment(meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice", text: "Hello")
        try await repo.saveSegments([seg])

        let segId = try await repo.segments(for: meeting.id)[0].id!
        try await repo.updateSegmentSpeaker(id: segId, speakerId: bob.id, speakerLabel: "Bob")

        let updated = try await repo.segments(for: meeting.id)
        XCTAssertEqual(updated[0].speakerId, bob.id)
        XCTAssertEqual(updated[0].speakerLabel, "Bob")
    }

    func testRenameSpeakerInMeeting() async throws {
        let meeting = makeMeeting()
        let speaker = makeSpeaker(name: "New Name")
        try await repo.save(meeting)
        try await speakerRepo.save(speaker)

        let seg1 = makeSegment(meetingId: meeting.id, speakerLabel: "SPEAKER_00", startTime: 0, endTime: 5, text: "A")
        let seg2 = makeSegment(meetingId: meeting.id, speakerLabel: "SPEAKER_00", startTime: 5, endTime: 10, text: "B")
        let seg3 = makeSegment(meetingId: meeting.id, speakerLabel: "SPEAKER_01", startTime: 10, endTime: 15, text: "C")
        try await repo.saveSegments([seg1, seg2, seg3])

        try await repo.renameSpeakerInMeeting(
            meetingId: meeting.id,
            oldLabel: "SPEAKER_00",
            newLabel: "New Name",
            speakerId: speaker.id
        )

        let segments = try await repo.segments(for: meeting.id)
        let renamed = segments.filter { $0.speakerLabel == "New Name" }
        XCTAssertEqual(renamed.count, 2)
        XCTAssertTrue(renamed.allSatisfy { $0.speakerId == speaker.id })

        let untouched = segments.filter { $0.speakerLabel == "SPEAKER_01" }
        XCTAssertEqual(untouched.count, 1)
    }

    /// two records sharing a label in one meeting — the rename moves
    /// only the chosen record's lines.
    func testRenameSpeakerInMeeting_onlyTheChosenRecord() async throws {
        let meeting = makeMeeting()
        let alice = makeSpeaker(name: "Alice")
        let bob = makeSpeaker(name: "Bob")
        let target = makeSpeaker(name: "Carol")
        try await repo.save(meeting)
        for s in [alice, bob, target] { try await speakerRepo.save(s) }
        try await repo.saveSegments([
            makeSegment(meetingId: meeting.id, speakerId: alice.id, speakerLabel: "Alice", startTime: 0, endTime: 5, text: "A"),
            makeSegment(meetingId: meeting.id, speakerId: bob.id, speakerLabel: "Alice", startTime: 5, endTime: 10, text: "B"),
        ])

        try await repo.renameSpeakerInMeeting(
            meetingId: meeting.id, oldLabel: "Alice", newLabel: "Carol", speakerId: target.id, fromSpeakerId: alice.id
        )

        let byText = Dictionary(uniqueKeysWithValues: try await repo.segments(for: meeting.id).map { ($0.text, $0) })
        XCTAssertEqual(byText["A"]?.speakerId, target.id)
        XCTAssertEqual(byText["B"]?.speakerId, bob.id, "the other record keeps its lines")
        XCTAssertEqual(byText["B"]?.speakerLabel, "Alice")
    }

    // MARK: - Status & Metadata Updates

    func testUpdateStatus() async throws {
        let meeting = makeMeeting(status: .recording)
        try await repo.save(meeting)

        try await repo.updateStatus(meeting.id, status: .transcribing)
        let fetched = try await repo.find(meeting.id)
        XCTAssertEqual(fetched?.status, .transcribing)

        try await repo.updateStatus(meeting.id, status: .done)
        let fetched2 = try await repo.find(meeting.id)
        XCTAssertEqual(fetched2?.status, .done)
    }

    func testUpdateEndTime() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)

        let endTime = Date(timeIntervalSince1970: 5000)
        try await repo.updateEndTime(meeting.id, endTime: endTime, duration: 3600)

        let fetched = try await repo.find(meeting.id)
        XCTAssertEqual(fetched?.endTime, endTime)
        XCTAssertEqual(fetched?.durationSeconds, 3600)
    }

    func testUpdateTitle() async throws {
        let meeting = makeMeeting(title: "Old Title")
        try await repo.save(meeting)

        try await repo.updateTitle(meeting.id, title: "New Title")

        let fetched = try await repo.find(meeting.id)
        XCTAssertEqual(fetched?.title, "New Title")
    }

    func testUpdateSeriesId() async throws {
        let meeting = makeMeeting()
        let series = MeetingSeries(name: "Weekly")
        try await repo.save(meeting)
        try await db.writer.write { db in try series.save(db) }

        try await repo.updateSeriesId(meeting.id, seriesId: series.id)
        let fetched = try await repo.find(meeting.id)
        XCTAssertEqual(fetched?.seriesId, series.id)

        // Unassign
        try await repo.updateSeriesId(meeting.id, seriesId: nil)
        let fetched2 = try await repo.find(meeting.id)
        XCTAssertNil(fetched2?.seriesId)
    }

    func testAssignSeriesToBatch() async throws {
        let m1 = makeMeeting(title: "M1")
        let m2 = makeMeeting(title: "M2")
        let m3 = makeMeeting(title: "M3")
        let series = MeetingSeries(name: "Weekly")

        try await repo.save(m1)
        try await repo.save(m2)
        try await repo.save(m3)
        try await db.writer.write { db in try series.save(db) }

        try await repo.assignSeriesToBatch([m1.id, m2.id], seriesId: series.id)

        let f1 = try await repo.find(m1.id)
        let f2 = try await repo.find(m2.id)
        let f3 = try await repo.find(m3.id)
        XCTAssertEqual(f1?.seriesId, series.id)
        XCTAssertEqual(f2?.seriesId, series.id)
        XCTAssertNil(f3?.seriesId, "M3 should not be assigned")
    }

    // MARK: - Full-Text Search

    func testSearchFindsWordsInDifferentLines() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)
        try await repo.saveSegments([
            makeSegment(meetingId: meeting.id, startTime: 0, endTime: 5, text: "We need to discuss the budget"),
            makeSegment(meetingId: meeting.id, startTime: 5, endTime: 10, text: "The timeline is tight"),
        ])

        let both = try await repo.meetingIds(matching: "budget timeline")
        XCTAssertEqual(both, [meeting.id])
        let missing = try await repo.meetingIds(matching: "budget roadmap")
        XCTAssertEqual(missing, [], "every word must occur somewhere in the meeting")
    }

    func testSearchFindsWordsInTitleAndDescription() async throws {
        var meeting = makeMeeting(title: "Квартальный обзор")
        meeting.description = "Итоги по найму"
        try await repo.save(meeting)
        try await repo.saveSegments([
            makeSegment(meetingId: meeting.id, startTime: 0, endTime: 5, text: "добрый день"),
        ])

        let titleOnly = try await repo.meetingIds(matching: "квартальный")
        XCTAssertEqual(titleOnly, [meeting.id])
        let descriptionOnly = try await repo.meetingIds(matching: "найму")
        XCTAssertEqual(descriptionOnly, [meeting.id])
        let mixed = try await repo.meetingIds(matching: "обзор найму добрый")
        XCTAssertEqual(mixed, [meeting.id])
    }

    /// The old search took the first 200 matching lines: one long meeting full
    /// of a common word crowded the others out.
    func testCommonWordDoesNotCrowdMeetingsOut() async throws {
        let long = makeMeeting()
        let short = makeMeeting()
        try await repo.save(long)
        try await repo.save(short)
        try await repo.saveSegments((0 ..< 250).map {
            makeSegment(meetingId: long.id, startTime: Double($0), endTime: Double($0) + 1, text: "ну значит так")
        })
        try await repo.saveSegments([
            makeSegment(meetingId: short.id, startTime: 0, endTime: 1, text: "значит договорились"),
        ])

        let found = try await repo.meetingIds(matching: "значит")
        XCTAssertEqual(found, [long.id, short.id])
    }

    // MARK: - meeting_speakers follows the segments

    func testReassigningLastSegmentUnlinksSpeakerFromMeeting() async throws {
        let meeting = makeMeeting()
        try await repo.save(meeting)
        let alice = makeSpeaker(name: "Alice"), bob = makeSpeaker(name: "Bob")
        try await speakerRepo.save(alice)
        try await speakerRepo.save(bob)
        try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: bob.id, diarizationLabel: "Bob")
        try await repo.saveSegments([makeSegment(meetingId: meeting.id, speakerId: bob.id, speakerLabel: "Bob")])
        let segments = try await repo.segments(for: meeting.id)
        let segment = try XCTUnwrap(segments.first)

        try await repo.updateSegmentSpeaker(id: try XCTUnwrap(segment.id), speakerId: alice.id, speakerLabel: "Alice")

        let linked = try await speakerRepo.speakersForMeeting(meeting.id).map { $0.speaker.id }
        XCTAssertEqual(linked, [alice.id], "Bob has no segments left; Alice just got her first")
    }
}
