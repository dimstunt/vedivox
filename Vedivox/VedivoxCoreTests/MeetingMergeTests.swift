import AVFoundation
import XCTest

/// Merge, split and their undos move audio and rows between two meetings.
/// Whatever fails on the way, no meeting may lose audio or transcript
/// (meeting-merge).
final class MeetingMergeTests: XCTestCase {
    private var db: DatabaseManager!
    private var meetings: MeetingRepository!
    private var root: URL!

    override func setUp() async throws {
        db = try makeTestDB()
        meetings = MeetingRepository(db: db)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-merge-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        MeetingRepository.crashAt = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Review of cli-meeting-edit

    /// Review 1: undoing a split puts the second part's lines back over the
    /// pre-split copy and deletes the part. After the part was merged with C,
    /// that deleted C's only audio; after it was trimmed, the lines landed off.
    func testUndoSplitIsRefusedOnceTheSecondPartWasMergedOrTrimmed() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let (_, second) = try await meetings.splitMeeting(a.id, atTime: 1, audioRoot: root)
        let c = try await makeRecorded("C", start: 5000)
        _ = try await meetings.mergeMeetings(second.id, c.id, audioRoot: root)

        let offered = await meetings.canUndoSplit(a.id, audioRoot: root)
        XCTAssertFalse(offered)
        do {
            try await meetings.undoSplit(a.id, audioRoot: root)
            XCTFail("expected a refusal")
        } catch MeetingRepository.SplitError.partEditedSince {}
        XCTAssertTrue(exists("mic_premerge.m4a", in: second.id), "the merged part keeps its undo copy")
        let part = try await meetings.find(second.id)
        XCTAssertNotNil(part)

        try await meetings.undoMerge(second.id, audioRoot: root)
        try await meetings.trimMeeting(second.id, keepFrom: 0.5, keepTo: 1.5, audioRoot: root)
        let afterTrim = await meetings.canUndoSplit(a.id, audioRoot: root)
        XCTAssertFalse(afterTrim)
    }

    /// Review 2: a database that cannot be read at launch says nothing about
    /// the commit — the journal and the joins wait for the next launch.
    func testRecoveryLeavesAMergeAloneWhenTheDatabaseCannotBeRead() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)
        MeetingRepository.crashAt = .journalWritten
        _ = try? await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
        MeetingRepository.crashAt = nil
        try await db.writer.write { try $0.execute(sql: "ALTER TABLE meetings RENAME TO meetings_away") }

        await meetings.recoverInterruptedMerges(audioRoot: root)

        try await db.writer.write { try $0.execute(sql: "ALTER TABLE meetings_away RENAME TO meetings") }
        XCTAssertTrue(exists(MeetingRepository.mergePendingFile, in: a.id))
        XCTAssertTrue(exists("mic_merged.m4a", in: a.id))
        XCTAssertTrue(exists("mic.m4a", in: b.id))
    }

    /// Review 4: finishing a merge whose journal is gone is an error, not a quiet success.
    func testFinishingAMergeWithoutItsJournalThrows() throws {
        let dir = try DatabaseManager.audioDirectory(for: "X", root: root)
        XCTAssertThrowsError(try MeetingRepository.finishMerge(in: dir, lateDir: dir.appendingPathComponent("none")))
    }

    /// Review 5: while a committed merge waits for the next launch, its meeting
    /// is not edited, and an old merge record next to the journal is not offered.
    func testAMeetingWithAnUnfinishedMergeIsNotEdited() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)
        let c = try await makeRecorded("C", start: 3000)
        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
        MeetingRepository.crashAt = .committed
        _ = try? await meetings.mergeMeetings(a.id, c.id, audioRoot: root)
        MeetingRepository.crashAt = nil

        XCTAssertFalse(meetings.canUndoMerge(a.id, audioRoot: root), "the old record describes another state")
        let dirsBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).count
        for edit in [
            { try await self.meetings.undoMerge(a.id, audioRoot: self.root) },
            { try await self.meetings.trimMeeting(a.id, keepFrom: 1, keepTo: 3, audioRoot: self.root) },
            { _ = try await self.meetings.splitMeeting(a.id, atTime: 1, audioRoot: self.root) },
        ] as [() async throws -> Void] {
            do {
                try await edit()
                XCTFail("expected a refusal")
            } catch MeetingRepository.SplitError.mergeUnfinished {}
        }
        let dirsAfter = try FileManager.default.contentsOfDirectory(atPath: root.path).count
        XCTAssertEqual(dirsAfter, dirsBefore, "a refused split leaves no empty directory for its second part")
    }

    /// Review 7: an Undo Merge that saved both meetings and stopped before the
    /// audio is finished by the next try — which used to overwrite B's audio and
    /// then delete its directory on the failed insert.
    func testUndoMergeStoppedAfterItsTransactionIsFinishedByTheNextTry() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)
        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
        MeetingRepository.crashAt = .undoCommitted
        _ = try? await meetings.undoMerge(a.id, audioRoot: root)
        MeetingRepository.crashAt = nil

        try await meetings.undoMerge(a.id, audioRoot: root)

        XCTAssertEqual(try seconds(of: "mic.m4a", in: b.id), 3, accuracy: 0.3, "B keeps its audio")
        XCTAssertEqual(try seconds(of: "mic.m4a", in: a.id), 3, accuracy: 0.3, "A is back to its own")
        XCTAssertFalse(meetings.canUndoMerge(a.id, audioRoot: root))
    }

    // MARK: A merge stopped midway (cli-meeting-edit, finding 3)

    /// Stopped before its transaction: the next launch drops the joins and
    /// both meetings are as they were.
    func testMergeStoppedBeforeTheCommitIsRolledBackAtLaunch() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)
        MeetingRepository.crashAt = .journalWritten
        do {
            _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
            XCTFail("expected the simulated crash")
        } catch is MeetingRepository.SimulatedCrash {}
        MeetingRepository.crashAt = nil

        await meetings.recoverInterruptedMerges(audioRoot: root)

        let restoredB = try await meetings.find(b.id)
        XCTAssertNotNil(restoredB)
        let aLines = try await meetings.segments(for: a.id).count
        let bLines = try await meetings.segments(for: b.id).count
        XCTAssertEqual(aLines, 1)
        XCTAssertEqual(bLines, 1)
        XCTAssertEqual(try seconds(of: "mic.m4a", in: a.id), 3, accuracy: 0.3, "A's own track")
        XCTAssertTrue(exists("mic.m4a", in: b.id), "B keeps its audio")
        XCTAssertFalse(exists("mic_merged.m4a", in: a.id))
        XCTAssertFalse(exists(MeetingRepository.mergePendingFile, in: a.id))
        XCTAssertFalse(meetings.canUndoMerge(a.id, audioRoot: root))
    }

    /// Stopped after its transaction: the next launch swaps the audio in and
    /// Undo Merge brings B back.
    func testMergeStoppedAfterTheCommitIsFinishedAtLaunchAndCanBeUndone() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)
        MeetingRepository.crashAt = .committed
        do {
            _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
            XCTFail("expected the simulated crash")
        } catch is MeetingRepository.SimulatedCrash {}
        MeetingRepository.crashAt = nil

        await meetings.recoverInterruptedMerges(audioRoot: root)

        let gone = try await meetings.find(b.id)
        XCTAssertNil(gone)
        let merged = try await meetings.segments(for: a.id).count
        XCTAssertEqual(merged, 2)
        XCTAssertEqual(try seconds(of: "mic.m4a", in: a.id), 6, accuracy: 0.4, "the joined track is in place")
        XCTAssertTrue(meetings.canUndoMerge(a.id, audioRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DatabaseManager.audioDirectoryURL(for: b.id, root: root).path))

        try await meetings.undoMerge(a.id, audioRoot: root)
        let back = try await meetings.find(b.id)
        XCTAssertNotNil(back)
        XCTAssertEqual(try seconds(of: "mic.m4a", in: a.id), 3, accuracy: 0.3)
    }

    // MARK: Undo

    /// Merge and its undo move lines between meetings; each meeting's speaker
    /// links must follow them, as trim's and split's do.
    func testMergeAndUndoKeepSpeakerLinksWithTheLines() async throws {
        let speakers = SpeakerRepository(db: db)
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)
        let ann = makeSpeaker(name: "Ann"), bob = makeSpeaker(name: "Bob")
        for (meeting, speaker) in [(a, ann), (b, bob)] {
            try await speakers.save(speaker)
            let lines = try await meetings.segments(for: meeting.id)
            let line = try XCTUnwrap(lines.first?.id)
            try await meetings.updateSegmentSpeaker(id: line, speakerId: speaker.id, speakerLabel: speaker.nameEn)
        }
        func linked(_ id: String) async throws -> Set<String> {
            Set(try await speakers.speakersForMeeting(id).map(\.speaker.id))
        }

        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
        let merged = try await linked(a.id)
        XCTAssertEqual(merged, [ann.id, bob.id])

        try await meetings.undoMerge(a.id, audioRoot: root)
        let first = try await linked(a.id), second = try await linked(b.id)
        XCTAssertEqual(first, [ann.id])
        XCTAssertEqual(second, [bob.id])
    }

    func testUndoMergeGivesEachMeetingItsSegmentsAndAudioBack() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)

        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
        let mergedTexts = try await meetings.segments(for: a.id).map(\.text)
        XCTAssertEqual(mergedTexts, ["A", "B"])

        try await meetings.undoMerge(a.id, audioRoot: root)

        let textsA = try await meetings.segments(for: a.id).map(\.text)
        let textsB = try await meetings.segments(for: b.id).map(\.text)
        XCTAssertEqual(textsA, ["A"])
        XCTAssertEqual(textsB, ["B"])
        XCTAssertEqual(try seconds(of: "mic.m4a", in: a.id), 3, accuracy: 0.3)
        XCTAssertEqual(try seconds(of: "mic.m4a", in: b.id), 3, accuracy: 0.3)
        XCTAssertFalse(meetings.canUndoMerge(a.id, audioRoot: root))
    }

    // MARK: Nothing is thrown away

    /// The later meeting's directory is deleted after a merge, so a track of
    /// it that did not make it into the join is gone for good.
    func testMergeIsRefusedWhenATrackOfTheLaterMeetingCannotBeJoined() async throws {
        // The earlier meeting has only the mic, the later one also recorded the call.
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000, files: ["mic.m4a", "system.m4a"])
        try await assertMergeRefused(a, b)
        XCTAssertTrue(exists("system.m4a", in: b.id))

        // The later meeting is not compressed yet (processing failed, or still runs).
        let c = try await makeRecorded("C", start: 3000, files: ["mic.wav"])
        try await assertMergeRefused(a, c)
        XCTAssertTrue(exists("mic.wav", in: c.id))
    }

    func testMergeIsRefusedWhileAMeetingIsStillBeingProcessed() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)
        try await meetings.updateStatus(b.id, status: .transcribing)

        try await assertMergeRefused(a, b)
        XCTAssertTrue(exists("mic.m4a", in: b.id))
    }

    /// An import whose processing failed keeps the imported file, and when no
    /// track was extracted from it that file is the only copy of the audio.
    func testMergeIsRefusedWhileTheLaterMeetingKeepsItsImportedOriginal() async throws {
        let a = try await makeRecorded("A", start: 1000)
        var b = try await makeRecorded("B", start: 2000, files: [])
        let original = DatabaseManager.audioDirectoryURL(for: b.id, root: root).appendingPathComponent("original.mov")
        try Data("not processed yet".utf8).write(to: original)
        b.source = .import
        b.sourceFilePath = original.path
        b.status = .error
        try await meetings.save(b)

        try await assertMergeRefused(a, b)
        XCTAssertTrue(exists("original.mov", in: b.id))
    }

    private func assertMergeRefused(_ first: Meeting, _ second: Meeting, line: UInt = #line) async throws {
        do {
            _ = try await meetings.mergeMeetings(first.id, second.id, audioRoot: root)
            XCTFail("the merge must be refused", line: line)
        } catch is MeetingRepository.SplitError {}
        for meeting in [first, second] {
            let texts = try await meetings.segments(for: meeting.id).map(\.text)
            XCTAssertEqual(texts, [meeting.title], "both meetings stay as they were", line: line)
        }
    }

    // MARK: Undo copies of one edit under another

    /// Undo Trim puts the pre-trim audio over the current track and
    /// reprocesses. Over a merged meeting that threw the second meeting away,
    /// audio and transcript.
    func testUndoTrimIsNotOfferedWhileAMeetingIsMerged() async throws {
        let a = try await makeRecorded("A", start: 1000, files: ["mic.m4a", "mic_pretrim.m4a"])
        let b = try await makeRecorded("B", start: 2000)
        XCTAssertTrue(meetings.canUndoTrim(a.id, audioRoot: root))

        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
        XCTAssertFalse(meetings.canUndoTrim(a.id, audioRoot: root))

        try await meetings.undoMerge(a.id, audioRoot: root)
        XCTAssertTrue(meetings.canUndoTrim(a.id, audioRoot: root), "undoing the merge makes the trim undoable again")
    }

    /// The undo copy must be of what the merge replaced. A second merge kept
    /// the copy of the first, so its undo restored A alone and B's audio
    /// existed nowhere any more.
    func testUndoOfASecondMergeRestoresTheResultOfTheFirst() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)
        let c = try await makeRecorded("C", start: 3000)
        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
        _ = try await meetings.mergeMeetings(a.id, c.id, audioRoot: root)

        try await meetings.undoMerge(a.id, audioRoot: root)

        let textsA = try await meetings.segments(for: a.id).map(\.text)
        let textsC = try await meetings.segments(for: c.id).map(\.text)
        XCTAssertEqual(textsA, ["A", "B"])
        XCTAssertEqual(textsC, ["C"])
        XCTAssertEqual(try seconds(of: "mic.m4a", in: a.id), 6, accuracy: 0.4)
    }

    /// After a trim the merge point recorded for the undo no longer matches
    /// the audio, so the undo goes — the same rule trim already has for split.
    func testTrimOfAMergedMeetingDropsTheMergeUndo() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let b = try await makeRecorded("B", start: 2000)
        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)

        try await meetings.trimMeeting(a.id, keepFrom: 1, keepTo: 5, audioRoot: root)

        XCTAssertFalse(meetings.canUndoMerge(a.id, audioRoot: root))
        XCTAssertFalse(exists("mic_premerge.m4a", in: a.id))
    }

    // MARK: Split

    /// The split used to delete the current track before its replacement was
    /// written, track by track: a failure on the second track left the first
    /// already cut, the second missing, the rows untouched and no undo.
    func testFailedSplitLeavesTheMeetingWhole() async throws {
        let a = try await makeRecorded("A", start: 1000, files: ["mic.m4a", "system.m4a"])
        let dir = DatabaseManager.audioDirectoryURL(for: a.id, root: root)
        try Data("not audio".utf8).write(to: dir.appendingPathComponent("system.m4a"))

        do {
            _ = try await meetings.splitMeeting(a.id, atTime: 1.5, audioRoot: root)
            XCTFail("a track that cannot be cut must fail the split")
        } catch {}

        XCTAssertEqual(try seconds(of: "mic.m4a", in: a.id), 3, accuracy: 0.3, "the mic track is not cut")
        XCTAssertTrue(exists("system.m4a", in: a.id))
        XCTAssertFalse(exists("mic_presplit.m4a", in: a.id), "no undo copy without a split to undo")
        let all = try await meetings.all()
        XCTAssertEqual(all.map(\.id), [a.id], "no second meeting")
        XCTAssertEqual(all.first?.durationSeconds, 3)
    }

    func testTheFirstHalfCanBeSplitAgain() async throws {
        let a = try await makeRecorded("A", start: 1000)

        _ = try await meetings.splitMeeting(a.id, atTime: 2, audioRoot: root)
        _ = try await meetings.splitMeeting(a.id, atTime: 1, audioRoot: root)

        XCTAssertEqual(try seconds(of: "mic.m4a", in: a.id), 1, accuracy: 0.3)
        XCTAssertEqual(try seconds(of: "mic_presplit.m4a", in: a.id), 2, accuracy: 0.3, "the undo copy is of the last split")
        let count = try await meetings.all().count
        XCTAssertEqual(count, 3)
    }

    // MARK: Trim

    /// The trim used to replace the tracks one by one and only then touch the
    /// rows: a failure on the second track left the mic cut and the call track
    /// and the transcript whole — every line off by the trimmed start.
    func testFailedTrimLeavesTheMeetingWhole() async throws {
        let a = try await makeRecorded("A", start: 1000, files: ["mic.m4a", "system.m4a"])
        let dir = DatabaseManager.audioDirectoryURL(for: a.id, root: root)
        try Data("not audio".utf8).write(to: dir.appendingPathComponent("system.m4a"))

        do {
            try await meetings.trimMeeting(a.id, keepFrom: 1, keepTo: 2, audioRoot: root)
            XCTFail("a track that cannot be cut must fail the trim")
        } catch {}

        XCTAssertEqual(try seconds(of: "mic.m4a", in: a.id), 3, accuracy: 0.3, "the mic track is not cut")
        XCTAssertFalse(exists("mic_pretrim.m4a", in: a.id), "no undo copy without a trim to undo")
        XCTAssertFalse(exists("mic.m4a.tmp", in: a.id), "the cut that did succeed is not left behind")
        let after = try await meetings.find(a.id)
        XCTAssertEqual(after?.durationSeconds, 3)
        let starts = try await meetings.segments(for: a.id).map(\.startTime)
        XCTAssertEqual(starts, [0], "the transcript is not shifted")
    }

    /// A segment across the cut used to keep its full length: a negative
    /// start, or an end past the end of the meeting.
    func testTrimClampsSegmentsToTheKeptRange() async throws {
        let a = try await makeRecorded("A", start: 1000) // one segment, 0–2 s

        try await meetings.trimMeeting(a.id, keepFrom: 1, keepTo: 1.5, audioRoot: root)

        let segment = try await meetings.segments(for: a.id).first
        XCTAssertEqual(segment?.startTime, 0)
        XCTAssertEqual(segment?.endTime ?? -1, 0.5, accuracy: 0.001)
        let after = try await meetings.find(a.id)
        XCTAssertEqual(after?.durationSeconds ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(try seconds(of: "mic_pretrim.m4a", in: a.id), 3, accuracy: 0.3, "the full track is the undo copy")
    }

    // MARK: The echo-suppressed mic

    /// The player prefers `mic_suppressed.m4a` over `mic.m4a`. Trim, split and
    /// merge used to leave it whole: the player kept the old length and the
    /// mic sounded off against the transcript by the trimmed start.
    private static let threeTracks = ["mic.m4a", "system.m4a", "mic_suppressed.m4a"]

    func testTrimAndUndoTrimTreatTheSuppressedMicLikeTheOtherTracks() async throws {
        var a = try await makeRecorded("A", start: 1000, files: Self.threeTracks)
        a.endTime = a.startTime.addingTimeInterval(3)
        try await meetings.save(a)
        let before = try await meetings.find(a.id)

        try await meetings.trimMeeting(a.id, keepFrom: 1, keepTo: 2.5, audioRoot: root)
        try await meetings.trimMeeting(a.id, keepFrom: 0.5, keepTo: 1.5, audioRoot: root)
        for file in Self.threeTracks {
            XCTAssertEqual(try seconds(of: file, in: a.id), 1, accuracy: 0.3, "\(file) is cut")
        }

        try await meetings.undoTrim(a.id, audioRoot: root)

        for file in Self.threeTracks {
            XCTAssertEqual(try seconds(of: file, in: a.id), 3, accuracy: 0.3, "\(file) is back whole")
        }
        let after = try await meetings.find(a.id)
        XCTAssertEqual(after?.startTime, before?.startTime, "the start is back from before the first trim")
        XCTAssertEqual(after?.durationSeconds, before?.durationSeconds)
        XCTAssertEqual(after?.endTime, before?.endTime)
        XCTAssertFalse(meetings.canUndoTrim(a.id, audioRoot: root))
    }

    /// A trim made by a build that kept no record of the start: the length
    /// still comes back, from the restored track.
    func testUndoTrimWithoutItsRecordTakesTheLengthFromTheTrack() async throws {
        let a = try await makeRecorded("A", start: 1000)
        try await meetings.trimMeeting(a.id, keepFrom: 1, keepTo: 2, audioRoot: root)
        let dir = DatabaseManager.audioDirectoryURL(for: a.id, root: root)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("trim_info.json"))

        try await meetings.undoTrim(a.id, audioRoot: root)

        let after = try await meetings.find(a.id)
        XCTAssertEqual(after?.durationSeconds ?? -1, 3, accuracy: 0.3)
    }

    /// cli-meeting-edit, finding 1: after trim → split, Undo Trim on part 1
    /// put the whole pre-trim audio back, part 2's stretch included. A split
    /// now drops the trim undo, as a trim drops the split undo.
    func testSplitDropsTheTrimUndo() async throws {
        let a = try await makeRecorded("A", start: 1000)
        try await meetings.trimMeeting(a.id, keepFrom: 0.5, keepTo: 3, audioRoot: root)
        XCTAssertTrue(meetings.canUndoTrim(a.id, audioRoot: root))

        _ = try await meetings.splitMeeting(a.id, atTime: 1, audioRoot: root)

        XCTAssertFalse(meetings.canUndoTrim(a.id, audioRoot: root))
        XCTAssertFalse(exists("mic_pretrim.m4a", in: a.id))
        XCTAssertFalse(exists("trim_info.json", in: a.id))
    }

    /// The split record sits with part 1; either part finds both (cli-meeting-edit).
    func testSplitPartsAreFoundFromEitherPart() async throws {
        let a = try await makeRecorded("A", start: 1000)
        let (_, second) = try await meetings.splitMeeting(a.id, atTime: 1, audioRoot: root)

        XCTAssertEqual(meetings.splitParts(of: a.id, audioRoot: root)?.second, second.id)
        XCTAssertEqual(meetings.splitParts(of: second.id, audioRoot: root)?.first, a.id)
        let unsplit = try await makeRecorded("C", start: 3000)
        XCTAssertNil(meetings.splitParts(of: unsplit.id, audioRoot: root))
    }

    /// Live check 2026-11-19: Undo Split set the length to the end of the
    /// last line — 217.34 s came back as 214.72, and the next split carried
    /// the error. The meeting's own length and end come back now.
    func testUndoSplitRestoresTheLengthNotTheEndOfTheLastLine() async throws {
        var a = try await makeRecorded("A", start: 1000)
        a.endTime = a.startTime.addingTimeInterval(3)
        try await meetings.save(a)
        _ = try await meetings.splitMeeting(a.id, atTime: 1, audioRoot: root)

        try await meetings.undoSplit(a.id, audioRoot: root)

        let after = try await meetings.find(a.id)
        XCTAssertEqual(after?.durationSeconds, 3, "the line ends at 2 s, the meeting at 3 s")
        XCTAssertEqual(after?.endTime, a.endTime)
    }

    /// A split recorded before the length was kept: the length comes from the restored track.
    func testUndoSplitWithoutTheKeptLengthTakesItFromTheTrack() async throws {
        let a = try await makeRecorded("A", start: 1000)
        _ = try await meetings.splitMeeting(a.id, atTime: 1, audioRoot: root)
        let info = DatabaseManager.audioDirectoryURL(for: a.id, root: root).appendingPathComponent("split_info.json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: info)) as? [String: Any])
        record["meeting1Duration"] = nil
        record["meeting1EndTime"] = nil
        try JSONSerialization.data(withJSONObject: record).write(to: info)

        try await meetings.undoSplit(a.id, audioRoot: root)

        let after = try await meetings.find(a.id)
        XCTAssertEqual(after?.durationSeconds ?? -1, 3, accuracy: 0.3)
    }

    func testSplitAndUndoSplitTreatTheSuppressedMicLikeTheOtherTracks() async throws {
        let a = try await makeRecorded("A", start: 1000, files: Self.threeTracks)

        let (_, second) = try await meetings.splitMeeting(a.id, atTime: 1, audioRoot: root)
        for file in Self.threeTracks {
            XCTAssertEqual(try seconds(of: file, in: a.id), 1, accuracy: 0.3, "first half of \(file)")
            XCTAssertEqual(try seconds(of: file, in: second.id), 2, accuracy: 0.3, "second half of \(file)")
        }

        try await meetings.undoSplit(a.id, audioRoot: root)
        for file in Self.threeTracks {
            XCTAssertEqual(try seconds(of: file, in: a.id), 3, accuracy: 0.3, "\(file) is back whole")
        }
    }

    func testMergeAndUndoMergeTreatTheSuppressedMicLikeTheOtherTracks() async throws {
        let a = try await makeRecorded("A", start: 1000, files: Self.threeTracks)
        let b = try await makeRecorded("B", start: 2000, files: Self.threeTracks)

        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
        for file in Self.threeTracks {
            XCTAssertEqual(try seconds(of: file, in: a.id), 6, accuracy: 0.3, "\(file) is joined")
        }

        try await meetings.undoMerge(a.id, audioRoot: root)
        for file in Self.threeTracks {
            XCTAssertEqual(try seconds(of: file, in: a.id), 3, accuracy: 0.3, "\(file) of the first meeting")
            XCTAssertEqual(try seconds(of: file, in: b.id), 3, accuracy: 0.3, "\(file) of the second meeting")
        }
    }

    /// Only the earlier meeting was echo-suppressed: its suppressed mic covers
    /// the first half alone, so the merged meeting plays the plain mic, and
    /// the undo gives the earlier meeting its suppressed mic back.
    func testMergeWithOneSuppressedMicFallsBackToThePlainMic() async throws {
        let a = try await makeRecorded("A", start: 1000, files: Self.threeTracks)
        let b = try await makeRecorded("B", start: 2000, files: ["mic.m4a", "system.m4a"])

        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)
        XCTAssertFalse(exists("mic_suppressed.m4a", in: a.id), "half a track would play under the whole transcript")

        try await meetings.undoMerge(a.id, audioRoot: root)
        XCTAssertEqual(try seconds(of: "mic_suppressed.m4a", in: a.id), 3, accuracy: 0.3)
        XCTAssertFalse(exists("mic_suppressed.m4a", in: b.id))
    }

    // MARK: What the later meeting carried

    /// The later meeting's row is deleted by the merge; its description and
    /// tags used to go with it, and Undo Merge could not bring them back.
    func testMergeKeepsTheLaterMeetingsDescriptionAndTags() async throws {
        var a = try await makeRecorded("A", start: 1000)
        a.description = "about A"
        try await meetings.save(a)
        var b = try await makeRecorded("B", start: 2000)
        b.description = "about B"
        try await meetings.save(b)
        let tags = TagRepository(db: db)
        try await tags.save(Tag(id: "t-shared", name: "shared"))
        try await tags.save(Tag(id: "t-late", name: "late only"))
        try await tags.addTagToMeeting(tagId: "t-shared", meetingId: a.id)
        try await tags.addTagToMeeting(tagId: "t-shared", meetingId: b.id)
        try await tags.addTagToMeeting(tagId: "t-late", meetingId: b.id)

        _ = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)

        let merged = try await meetings.find(a.id)
        XCTAssertEqual(merged?.description, "about A\n\nabout B")
        let mergedTags = try await tags.tagsForMeeting(a.id).map(\.id).sorted()
        XCTAssertEqual(mergedTags, ["t-late", "t-shared"])

        try await meetings.undoMerge(a.id, audioRoot: root)

        let restoredA = try await meetings.find(a.id)
        let restoredB = try await meetings.find(b.id)
        XCTAssertEqual(restoredA?.description, "about A")
        XCTAssertEqual(restoredB?.description, "about B")
        let restoredTags = try await tags.tagsForMeeting(b.id).map(\.id).sorted()
        XCTAssertEqual(restoredTags, ["t-late", "t-shared"])
        // cli-meeting-edit, finding 6: the tag the merge brought leaves A; A's own stays.
        let earlyTags = try await tags.tagsForMeeting(a.id).map(\.id).sorted()
        XCTAssertEqual(earlyTags, ["t-shared"])
    }

    // MARK: A meeting a quit or a crash left without its end

    /// The join puts the later audio after the earlier track's end. A meeting
    /// recovered after a quit has no durationSeconds, and the later lines were
    /// shifted by 0 — laid over the earlier ones.
    func testMergeShiftsTheLaterMeetingByTheEarlierTrackWhenItsDurationIsMissing() async throws {
        var a = try await makeRecorded("A", start: 1000)
        a.durationSeconds = nil
        a.endTime = nil
        try await meetings.save(a)
        let b = try await makeRecorded("B", start: 2000)

        let merged = try await meetings.mergeMeetings(a.id, b.id, audioRoot: root)

        let starts = try await meetings.segments(for: a.id).map(\.startTime)
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.last ?? -1, 3, accuracy: 0.3, "B's line starts where A's track ends")
        XCTAssertEqual(merged.durationSeconds ?? -1, 6, accuracy: 0.4)
    }

    func testRecoveredMeetingGetsItsDurationFromTheTrack() async throws {
        var a = try await makeRecorded("A", start: 1000)
        a.durationSeconds = nil
        a.endTime = nil
        try await meetings.save(a)
        let mic = DatabaseManager.audioDirectoryURL(for: a.id, root: root).appendingPathComponent("mic.m4a")

        await meetings.fillMissingDuration(a.id, from: mic)

        let after = try await meetings.find(a.id)
        let duration = try XCTUnwrap(after?.durationSeconds)
        XCTAssertEqual(duration, 3, accuracy: 0.3)
        let end = try XCTUnwrap(after?.endTime)
        XCTAssertEqual(end.timeIntervalSince(a.startTime), duration, accuracy: 0.01)
    }

    /// A stop that did write the end keeps it: the wall clock is what the user saw.
    func testADurationAlreadySetIsKept() async throws {
        var a = try await makeRecorded("A", start: 1000)
        a.durationSeconds = 2.5
        try await meetings.save(a)
        let mic = DatabaseManager.audioDirectoryURL(for: a.id, root: root).appendingPathComponent("mic.m4a")

        await meetings.fillMissingDuration(a.id, from: mic)

        let after = try await meetings.find(a.id)
        XCTAssertEqual(after?.durationSeconds, 2.5)
    }

    // MARK: Fixtures

    /// A finished 3 s meeting with one segment (its text is the title) and the
    /// given audio files in its directory.
    private func makeRecorded(_ title: String, start: TimeInterval, files: [String] = ["mic.m4a"]) async throws -> Meeting {
        var meeting = makeMeeting(title: title, startTime: Date(timeIntervalSince1970: start))
        meeting.durationSeconds = 3
        let dir = try DatabaseManager.audioDirectory(for: meeting.id, root: root)
        for file in files {
            try await writeAudio(dir.appendingPathComponent(file))
        }
        if files.contains("mic.m4a") { meeting.micAudioPath = dir.appendingPathComponent("mic.m4a").path }
        if files.contains("system.m4a") { meeting.systemAudioPath = dir.appendingPathComponent("system.m4a").path }
        try await meetings.save(meeting)
        try await meetings.saveSegments([makeSegment(meetingId: meeting.id, startTime: 0, endTime: 2, text: title)])
        return meeting
    }

    /// 3 s of noise (so the join's energy check has something to find), as WAV
    /// or — by extension — AAC.
    private func writeAudio(_ url: URL, seconds: Double = 3) async throws {
        let wav = url.pathExtension == "wav" ? url : url.deletingPathExtension().appendingPathExtension("fixture.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let frames = AVAudioFrameCount(seconds * 48000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0 ..< Int(frames) { buffer.floatChannelData![0][i] = Float.random(in: -0.3 ... 0.3) }
        try AVAudioFile(forWriting: wav, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            .write(from: buffer)
        guard wav != url else { return }
        try await AudioConverter.compressToAAC(input: wav, output: url)
        try FileManager.default.removeItem(at: wav)
    }

    private func seconds(of file: String, in meetingId: String) throws -> Double {
        let url = DatabaseManager.audioDirectoryURL(for: meetingId, root: root).appendingPathComponent(file)
        let audio = try AVAudioFile(forReading: url)
        return Double(audio.length) / audio.fileFormat.sampleRate
    }

    private func exists(_ file: String, in meetingId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: DatabaseManager.audioDirectoryURL(for: meetingId, root: root).appendingPathComponent(file).path
        )
    }
}
