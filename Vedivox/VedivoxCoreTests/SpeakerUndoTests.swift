import GRDB
import XCTest

/// a speaker merge or rename put back by Edit → Undo.
final class SpeakerUndoTests: XCTestCase {
    private var db: DatabaseManager!
    private var repo: SpeakerRepository!
    private var meetingRepo: MeetingRepository!

    override func setUp() async throws {
        db = try makeTestDB()
        repo = SpeakerRepository(db: db)
        meetingRepo = MeetingRepository(db: db)
    }

    private struct State: Equatable {
        let segments: [String: String?]
        let links: Set<String>
        let speakers: Set<String>
        let marks: [String?]
    }

    private func state() async throws -> State {
        try await db.reader.read { db in
            let segs = try Row.fetchAll(db, sql: "SELECT text, speakerId FROM transcript_segments")
            let links = try Row.fetchAll(db, sql: "SELECT meetingId, speakerId FROM meeting_speakers")
            return State(
                segments: Dictionary(uniqueKeysWithValues: segs.map { ($0["text"] as String, $0["speakerId"] as String?) }),
                links: Set(links.map { ($0["meetingId"] as String) + "|" + ($0["speakerId"] as String) }),
                speakers: Set(try String.fetchAll(db, sql: "SELECT id FROM speakers")),
                marks: try String?.fetchAll(db, sql: "SELECT speakerId FROM meeting_marks ORDER BY id")
            )
        }
    }

    func testMergeIsPutBack() async throws {
        let alice = Speaker(nameEn: "Alice", isConfirmed: true)
        let bob = Speaker(nameEn: "Bob", isMe: true, isConfirmed: true)
        try await repo.save(alice)
        try await repo.save(bob)
        let m1 = makeMeeting()
        let m2 = makeMeeting()
        for (m, s) in [(m1, alice), (m1, bob), (m2, bob)] {
            try await meetingRepo.save(m)
            try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: s.id, diarizationLabel: nil)
        }
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: m1.id, speakerId: alice.id, speakerLabel: "Alice", text: "a1"),
            makeSegment(meetingId: m1.id, speakerId: bob.id, speakerLabel: "Bob", startTime: 6, endTime: 8, text: "b1"),
            makeSegment(meetingId: m2.id, speakerId: bob.id, speakerLabel: "Bob", text: "b2"),
        ])
        try await MarkRepository(db: db).add(MeetingMark(
            meetingId: m2.id, startTime: 0, endTime: 5, track: .mic, kind: .speaker, speakerId: bob.id
        ))
        let before = try await state()

        let undo = try await SpeakerUndo.capture(speakerIds: [bob.id], rows: [alice.id], db: db)
        try await repo.mergeSpeakers(targetId: alice.id, sourceIds: [bob.id])
        let merged = try await state()
        XCTAssertNotEqual(merged, before)

        try await undo.restore(db: db)

        let after = try await state()
        XCTAssertEqual(after, before)
        let bobBack = try await repo.find(bob.id)
        let aliceBack = try await repo.find(alice.id)
        XCTAssertEqual(bobBack?.isMe, true)
        XCTAssertEqual(aliceBack?.isMe, false, "the owner mark goes back to Bob")
    }

    /// Delete Speaker is undone with its name, voice, lines and verdicts;
    /// the anonymous records the delete minted go.
    func testDeleteIsPutBack() async throws {
        let alice = Speaker(nameEn: "Alice", nameRu: "Алиса", isConfirmed: true, embedding: Data([1, 2, 3]))
        try await repo.save(alice)
        try await db.writer.write { try $0.execute(sql: "UPDATE speakers SET embeddingV2 = x'0405' WHERE id = ?", arguments: [alice.id]) }
        let m1 = makeMeeting(), m2 = makeMeeting()
        for m in [m1, m2] {
            try await meetingRepo.save(m)
            try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: alice.id, diarizationLabel: nil)
        }
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: m1.id, speakerId: alice.id, speakerLabel: "Alice", text: "a1"),
            makeSegment(meetingId: m2.id, speakerId: alice.id, speakerLabel: "Alice", text: "a2"),
        ])
        try await MarkRepository(db: db).add(MeetingMark(
            meetingId: m2.id, startTime: 0, endTime: 5, track: .mic, kind: .speaker, speakerId: alice.id
        ))
        let before = try await state()

        let undo = try await SpeakerUndo.capture(speakerIds: [alice.id], db: db)
        try await repo.deleteSpeaker(alice.id)
        let deleted = try await repo.find(alice.id)
        XCTAssertNil(deleted)

        try await undo.sealed(db: db).restore(db: db)

        let after = try await state()
        XCTAssertEqual(after, before)
        let back = try await repo.find(alice.id)
        XCTAssertEqual(back?.nameRu, "Алиса")
        XCTAssertEqual(back?.embedding, Data([1, 2, 3]))
        let v2 = try await db.reader.read { try Data.fetchOne($0, sql: "SELECT embeddingV2 FROM speakers WHERE id = ?", arguments: [alice.id]) }
        XCTAssertEqual(v2, Data([4, 5]))
    }

    func testRenameToANewNameIsPutBackAndTheNewRecordGoes() async throws {
        let anon = makeSpeaker(name: "speaker_1")
        try await repo.save(anon)
        let m = makeMeeting()
        try await meetingRepo.save(m)
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: anon.id, diarizationLabel: "speaker_1")
        try await meetingRepo.saveSegments([makeSegment(meetingId: m.id, speakerId: anon.id, speakerLabel: "speaker_1", text: "x")])
        let before = try await state()

        let undo = try await SpeakerUndo.capture(speakerIds: [anon.id], meetingIds: [m.id], db: db)
        let carol = try await repo.findOrCreateSpeaker(name: "Carol")
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: carol.id, diarizationLabel: "speaker_1")
        try await meetingRepo.renameSpeakerInMeeting(
            meetingId: m.id, oldLabel: "speaker_1", newLabel: "Carol", speakerId: carol.id, fromSpeakerId: anon.id
        )
        try await repo.cleanupOrphanedMeetingSpeakers(meetingId: m.id)

        try await undo.restore(db: db)

        let after = try await state()
        XCTAssertEqual(after, before)
        let label = try await meetingRepo.segments(for: m.id).first?.speakerLabel
        XCTAssertEqual(label, "speaker_1")
    }

    func testRefusedAfterTheMeetingWasReprocessed() async throws {
        let alice = Speaker(nameEn: "Alice", isConfirmed: true)
        try await repo.save(alice)
        let m = makeMeeting()
        try await meetingRepo.save(m)
        try await meetingRepo.saveSegments([makeSegment(meetingId: m.id, speakerId: alice.id, speakerLabel: "Alice")])
        let undo = try await SpeakerUndo.capture(speakerIds: [alice.id], db: db)
        try await meetingRepo.saveSegments([makeSegment(meetingId: m.id, speakerLabel: "UNKNOWN", startTime: 9, endTime: 10)])

        do {
            try await undo.restore(db: db)
            XCTFail("a changed meeting must refuse the undo")
        } catch SpeakerUndo.UndoError.dataChanged {}
    }

    // MARK: - A change made since refuses the undo

    private func assertRefused(_ undo: SpeakerUndo, _ why: String, line: UInt = #line) async {
        do {
            try await undo.restore(db: db)
            XCTFail(why, line: line)
        } catch SpeakerUndo.UndoError.dataChanged {
        } catch {
            XCTFail("\(error)", line: line)
        }
    }

    private func renamedBob() async throws -> (bob: Speaker, undo: SpeakerUndo) {
        let bob = Speaker(nameEn: "Bob", isConfirmed: true)
        try await repo.save(bob)
        let undo = try await SpeakerUndo.capture(speakerIds: [bob.id], db: db)
        try await repo.updateProfile(bob.id, nameEn: "Robert", nameRu: nil, nickname: nil)
        return (bob, try await undo.sealed(db: db))
    }

    func testRenameThenDeleteDoesNotResurrectTheSpeaker() async throws {
        let (bob, undo) = try await renamedBob()
        try await repo.deleteSpeaker(bob.id)

        await assertRefused(undo, "the undo would bring a deleted speaker back")
        let found = try await repo.find(bob.id)
        XCTAssertNil(found)
    }

    func testRenameThenThisIsMeKeepsTheOwner() async throws {
        try await repo.save(Speaker(nameEn: "Me", isMe: true, isConfirmed: true))
        let (bob, undo) = try await renamedBob()
        try await repo.markAsMe(bob.id)

        await assertRefused(undo, "the undo would take the owner mark off Bob and give it to nobody")
        let owner = try await repo.findMe()
        XCTAssertEqual(owner?.id, bob.id)
    }

    /// The record a rename in a meeting creates goes with the undo — owner mark and all.
    func testRenameInMeetingThenThisIsMeKeepsTheOwner() async throws {
        let anon = makeSpeaker(name: "speaker_1")
        try await repo.save(anon)
        let m = makeMeeting()
        try await meetingRepo.save(m)
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: anon.id, diarizationLabel: "speaker_1")
        try await meetingRepo.saveSegments([makeSegment(meetingId: m.id, speakerId: anon.id, speakerLabel: "speaker_1")])

        let captured = try await SpeakerUndo.capture(speakerIds: [anon.id], meetingIds: [m.id], db: db)
        let carol = try await repo.findOrCreateSpeaker(name: "Carol")
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: carol.id, diarizationLabel: "speaker_1")
        try await meetingRepo.renameSpeakerInMeeting(
            meetingId: m.id, oldLabel: "speaker_1", newLabel: "Carol", speakerId: carol.id, fromSpeakerId: anon.id
        )
        try await repo.cleanupOrphanedMeetingSpeakers(meetingId: m.id)
        let undo = try await captured.sealed(db: db)
        try await repo.markAsMe(carol.id)

        await assertRefused(undo, "the undo would delete the owner's record")
        let owner = try await repo.findMe()
        XCTAssertEqual(owner?.id, carol.id)
    }

    func testMergeThenAHandReassignedLineIsNotRolledBack() async throws {
        let alice = Speaker(nameEn: "Alice", isConfirmed: true)
        let bob = Speaker(nameEn: "Bob", isConfirmed: true)
        let carol = Speaker(nameEn: "Carol", isConfirmed: true)
        for speaker in [alice, bob, carol] { try await repo.save(speaker) }
        let m = makeMeeting()
        try await meetingRepo.save(m)
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: bob.id, diarizationLabel: nil)
        try await meetingRepo.saveSegments([makeSegment(meetingId: m.id, speakerId: bob.id, speakerLabel: "Bob")])
        let line = try await meetingRepo.segments(for: m.id).compactMap(\.id)

        let captured = try await SpeakerUndo.capture(speakerIds: [bob.id], rows: [alice.id], db: db)
        try await repo.mergeSpeakers(targetId: alice.id, sourceIds: [bob.id])
        let undo = try await captured.sealed(db: db)
        _ = try await SpeakerVerdicts(db: db).assign(meetingId: m.id, segmentIds: line, to: .existing(speakerId: carol.id))

        await assertRefused(undo, "the undo would hand Carol's line back to Bob under a verdict that says Carol")
        let holder = try await meetingRepo.segments(for: m.id).first?.speakerId
        XCTAssertEqual(holder, carol.id)
    }

    /// Through the real UndoManager: registering seals the snapshot, and ⌘Z
    /// hands the refusal to whoever registered it.
    @MainActor
    func testCommandZAfterADeleteReportsTheRefusal() async throws {
        let bob = Speaker(nameEn: "Bob", isConfirmed: true)
        try await repo.save(bob)
        let undo = try await SpeakerUndo.capture(speakerIds: [bob.id], db: db)
        try await repo.updateProfile(bob.id, nameEn: "Robert", nameRu: nil, nickname: nil)
        let manager = UndoManager()
        let reported = expectation(description: "the caller hears how the undo went")
        var failure: String?
        await manager.registerSpeakerUndo(undo, named: "Rename Speaker", db: db) {
            failure = $0
            reported.fulfill()
        }
        try await repo.deleteSpeaker(bob.id)

        manager.undo()
        await fulfillment(of: [reported], timeout: 5)

        XCTAssertEqual(failure?.hasPrefix("Could not undo rename speaker"), true, failure ?? "no failure reported")
        let found = try await repo.find(bob.id)
        XCTAssertNil(found)
    }

    /// ⌘Z usually runs after the screen that registered the undo is gone (Speakers →
    /// a meeting, or back), and with it the view's own alert state: the meeting
    /// window dropped the failure outright, the Speakers screen lost it on the
    /// way. Every registration hands it to AppState, which the window shows.
    /// Scans the sources (bundled as a resource), the way DesignSystemLiteralTests does.
    func testEveryViewHandsARefusedUndoToTheWindow() throws {
        let views = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Views", withExtension: nil))
        let sources = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
        func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

        let registering = sources.filter { $0.text.contains("registerSpeakerUndo(") }
        XCTAssertFalse(registering.isEmpty, "no registerSpeakerUndo call under \(views.path)")
        for source in registering {
            XCTAssertEqual(
                count("appState.speakerUndoFailure = failure", in: source.text),
                count("registerSpeakerUndo(", in: source.text),
                "\(source.name): a speaker undo is registered without reporting its failure"
            )
        }
        XCTAssertEqual(
            sources.filter { $0.text.contains("Text(appState.speakerUndoFailure") }.map(\.name), ["ContentView.swift"],
            "the main window is the one place that shows it"
        )
    }

    /// Stacked undos still unwind: putting the merge back leaves what the rename left.
    func testUndosUnwindInOrder() async throws {
        let alice = Speaker(nameEn: "Alice", isConfirmed: true)
        let bob = Speaker(nameEn: "Bob", isMe: true, isConfirmed: true)
        try await repo.save(alice)
        try await repo.save(bob)
        let m = makeMeeting()
        try await meetingRepo.save(m)
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: bob.id, diarizationLabel: nil)
        try await meetingRepo.saveSegments([makeSegment(meetingId: m.id, speakerId: bob.id, speakerLabel: "Bob")])
        try await MarkRepository(db: db).add(MeetingMark(
            meetingId: m.id, startTime: 0, endTime: 5, track: .mic, kind: .speaker, speakerId: bob.id
        ))
        let before = try await state()

        var rename = try await SpeakerUndo.capture(speakerIds: [bob.id], db: db)
        try await repo.updateProfile(bob.id, nameEn: "Robert", nameRu: nil, nickname: nil)
        try await repo.updateSegmentLabelsForSpeaker(bob.id, newLabel: "Robert")
        rename = try await rename.sealed(db: db)
        var merge = try await SpeakerUndo.capture(speakerIds: [bob.id], rows: [alice.id], db: db)
        try await repo.mergeSpeakers(targetId: alice.id, sourceIds: [bob.id])
        merge = try await merge.sealed(db: db)

        try await merge.restore(db: db)
        try await rename.restore(db: db)

        let after = try await state()
        XCTAssertEqual(after, before)
        let label = try await meetingRepo.segments(for: m.id).first?.speakerLabel
        XCTAssertEqual(label, "Bob")
    }

    /// `embeddingV2` lives outside the `Speaker` struct; the offline diarizer matches on it.
    func testMergeUndoPutsBackTheOfflineCanonicals() async throws {
        let alice = Speaker(nameEn: "Alice", isConfirmed: true)
        let bob = Speaker(nameEn: "Bob", isConfirmed: true)
        try await repo.save(alice)
        try await repo.save(bob)
        let m = makeMeeting()
        try await meetingRepo.save(m)
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: alice.id, diarizationLabel: nil)
        try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: bob.id, diarizationLabel: nil)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: m.id, speakerId: alice.id, speakerLabel: "Alice", text: "a1"),
            makeSegment(meetingId: m.id, speakerId: bob.id, speakerLabel: "Bob", startTime: 6, endTime: 8, text: "b1"),
        ])
        let va = Speaker.encodeEmbedding([Float](repeating: 0.1, count: 256))
        let vb = Speaker.encodeEmbedding([Float](repeating: -0.2, count: 256))
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE speakers SET embeddingV2 = ? WHERE id = ?", arguments: [va, alice.id])
            try db.execute(sql: "UPDATE speakers SET embeddingV2 = ? WHERE id = ?", arguments: [vb, bob.id])
        }

        let undo = try await SpeakerUndo.capture(speakerIds: [bob.id], rows: [alice.id], db: db)
        try await repo.mergeSpeakers(targetId: alice.id, sourceIds: [bob.id])
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE speakers SET embeddingV2 = ? WHERE id = ?", arguments: [vb, alice.id])
        }
        try await undo.restore(db: db)

        let v2 = try await db.reader.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, embeddingV2 FROM speakers").map {
                ($0["id"] as String, $0["embeddingV2"] as Data?)
            })
        }
        XCTAssertEqual(v2[bob.id] ?? nil, vb)
        XCTAssertEqual(v2[alice.id] ?? nil, va)
    }
}
