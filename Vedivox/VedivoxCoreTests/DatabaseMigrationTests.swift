import XCTest
import GRDB

final class DatabaseMigrationTests: XCTestCase {

    func testAllMigrationsPass() async throws {
        // Creating an in-memory DB runs all 4 migrations (v1..v4)
        let db = try makeTestDB()

        // Verify tables exist by doing basic operations
        let meetings = try await MeetingRepository(db: db).all()
        XCTAssertTrue(meetings.isEmpty)

        let speakers = try await SpeakerRepository(db: db).all()
        XCTAssertTrue(speakers.isEmpty)

        let series = try await SeriesRepository(db: db).all()
        XCTAssertTrue(series.isEmpty)

        let tags = try await TagRepository(db: db).all()
        XCTAssertTrue(tags.isEmpty)
    }

    // MARK: - v21: micMultiSpeaker → foreignVoiceDecision

    /// The mode column stops being about processing and becomes the decision,
    /// so it is renamed along with its meaning and gains the two states a
    /// boolean could not hold. Values are carried over on a database that
    /// really still had the old column.
    func testV21_carriesValuesOverFromTheOldColumn() throws {
        // Its own defaults suite: in `.standard` the key is deleted by every
        // other test process that migrates a database at the same moment.
        let dismissedKey = "unknownPromptDismissedMeetings"
        let suite = "v21-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        DatabaseManager.legacyDefaults = defaults
        defer {
            DatabaseManager.legacyDefaults = .standard
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(["answered"], forKey: dismissedKey)

        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v20-meeting-marks")

        try queue.write { db in
            for (id, mode) in [("multi", 1), ("plain", 0), ("answered", 0)] {
                try db.execute(sql: """
                    INSERT INTO meetings (id, title, startTime, micMultiSpeaker)
                    VALUES (?, ?, CURRENT_TIMESTAMP, ?)
                    """, arguments: [id, id, mode])
            }
        }

        try DatabaseManager.migrator.migrate(queue)

        let decisions: [String: String] = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, foreignVoiceDecision FROM meetings")
                .reduce(into: [:]) { $0[$1["id"] as String] = $1["foreignVoiceDecision"] as String }
        }
        XCTAssertEqual(decisions["multi"], ForeignVoiceDecision.kept.rawValue,
                       "«несколько людей на микрофоне» означало «показывай их» — это «оставлено»")
        XCTAssertEqual(decisions["answered"], ForeignVoiceDecision.kept.rawValue,
                       "ответ «участник» из UserDefaults переезжает во встречу")
        XCTAssertEqual(decisions["plain"], ForeignVoiceDecision.undecided.rawValue,
                       "остальные — не решено, разбор предложат при открытии")

        // The list stops being used: «не решено» was inexpressible in it.
        XCTAssertNil(defaults.stringArray(forKey: dismissedKey))

        let columns: [String] = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(meetings)").map { $0["name"] }
        }
        XCTAssertFalse(columns.contains("micMultiSpeaker"))
        XCTAssertTrue(columns.contains("foreignVoiceDecision"))
    }

    /// Fresh meetings start «не решено» — the state a boolean could not hold.
    func testV21_freshMeetingIsUndecided() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        let stored = try await meetingRepo.find(meeting.id)
        XCTAssertEqual(stored?.foreignVoiceDecision, .undecided)
    }

    // MARK: - v22: одна автозапись — одна встреча (speaker-row-per-mint)

    /// Общая автозапись на три встречи разрезается: оригинал остаётся на самой
    /// ранней, остальные встречи получают свои записи с той же подписью и hue;
    /// реплики не теряются и не меняют подпись; слепки разрезанных обнулены.
    /// Подтверждённый спикер с несколькими встречами не тронут.
    func testV22_splitsSharedAutoRowPerMeeting() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v21-foreign-voice-decision")

        try queue.write { db in
            for (id, day) in [("m1", "2026-01-01"), ("m2", "2026-02-01"), ("m3", "2026-03-01")] {
                try db.execute(sql: "INSERT INTO meetings (id, title, startTime) VALUES (?, ?, ?)",
                               arguments: [id, id, day])
            }
            try db.execute(sql: """
                INSERT INTO speakers (id, nameEn, isConfirmed, embedding, embeddingV2, hue)
                VALUES ('shared', 'speaker_1', 0, x'00000000', x'00000000', 42.0)
                """)
            try db.execute(sql: """
                INSERT INTO speakers (id, nameEn, isConfirmed, embedding)
                VALUES ('nina', 'Нина', 1, x'11111111')
                """)
            for m in ["m1", "m2", "m3"] {
                try db.execute(sql: "INSERT INTO meeting_speakers (meetingId, speakerId, diarizationLabel) VALUES (?, 'shared', 'speaker_1')",
                               arguments: [m])
                for i in 0 ..< 2 {
                    try db.execute(sql: """
                        INSERT INTO transcript_segments (meetingId, speakerId, speakerLabel, source, startTime, endTime, text)
                        VALUES (?, 'shared', 'speaker_1', 'system', ?, ?, 't')
                        """, arguments: [m, Double(i), Double(i) + 1])
                }
            }
            for m in ["m1", "m2"] {
                try db.execute(sql: "INSERT INTO meeting_speakers (meetingId, speakerId, diarizationLabel) VALUES (?, 'nina', 'Нина')",
                               arguments: [m])
            }
        }

        try DatabaseManager.migrator.migrate(queue, upTo: "v22-speaker-row-per-meeting")

        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, COUNT(DISTINCT ms.meetingId) AS mc
                FROM speakers s LEFT JOIN meeting_speakers ms ON ms.speakerId = s.id
                WHERE s.nameEn = 'speaker_1' GROUP BY s.id
                """)
            XCTAssertEqual(rows.count, 3, "три встречи — три записи speaker_1")
            for row in rows {
                XCTAssertEqual(row["mc"] as Int, 1, "у каждой записи ровно одна встреча")
            }

            let originalMeeting = try String.fetchOne(
                db, sql: "SELECT meetingId FROM meeting_speakers WHERE speakerId = 'shared'"
            )
            XCTAssertEqual(originalMeeting, "m1", "оригинал остался на самой ранней встрече")

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments WHERE speakerLabel = 'speaker_1'"),
                6, "ни одна реплика не потеряна и не сменила подпись"
            )
            let mismatches = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_segments ts
                JOIN meeting_speakers ms ON ms.speakerId = ts.speakerId
                WHERE ts.speakerLabel = 'speaker_1' AND ms.meetingId != ts.meetingId
                """)
            XCTAssertEqual(mismatches, 0, "каждая реплика указывает на запись своей встречи")

            XCTAssertEqual(
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM speakers
                    WHERE nameEn = 'speaker_1' AND (embedding IS NOT NULL OR embeddingV2 IS NOT NULL)
                    """),
                0, "слепки разрезанных обнулены — среднее по десяткам людей не наследуется"
            )
            let hues = try Double.fetchAll(db, sql: "SELECT hue FROM speakers WHERE nameEn = 'speaker_1'")
            XCTAssertEqual(hues, [42.0, 42.0, 42.0], "цвет в транскриптах не меняется")

            let nina = try Row.fetchOne(db, sql: "SELECT * FROM speakers WHERE id = 'nina'")!
            XCTAssertNotNil(nina["embedding"] as Data?, "подтверждённый спикер не тронут")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_speakers WHERE speakerId = 'nina'"),
                2
            )
        }
    }

    /// Автозапись с одной встречей — уже в правильной форме: не тронута.
    func testV22_singleMeetingAutoRowUntouched() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v21-foreign-voice-decision")

        try queue.write { db in
            try db.execute(sql: "INSERT INTO meetings (id, title, startTime) VALUES ('m1', 'm1', '2026-01-01')")
            try db.execute(sql: """
                INSERT INTO speakers (id, nameEn, isConfirmed, embedding, hue)
                VALUES ('solo', 'speaker_1', 0, x'00000000', 7.0)
                """)
            try db.execute(sql: "INSERT INTO meeting_speakers (meetingId, speakerId, diarizationLabel) VALUES ('m1', 'solo', 'speaker_1')")
        }

        try DatabaseManager.migrator.migrate(queue)

        try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM speakers WHERE nameEn = 'speaker_1'")!
            XCTAssertEqual(row["id"] as String, "solo")
            XCTAssertEqual(row["hue"] as Double, 7.0)
            XCTAssertNotNil(row["embedding"] as Data?, "слепок единственной встречи на месте")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speakers"), 1)
        }
    }

    /// empty rows left by the old ASR fallback go away, and so does
    /// the speaker link that only they held; hand-edited empty rows stay.
    func testV25_dropsEmptyUneditedSegments() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v24-mark-text")

        try queue.write { db in
            try db.execute(sql: "INSERT INTO meetings (id, title, startTime) VALUES ('m1', 'm1', '2026-01-01')")
            try db.execute(sql: "INSERT INTO speakers (id, nameEn) VALUES ('me', 'me'), ('other', 'other')")
            try db.execute(sql: """
                INSERT INTO transcript_segments (meetingId, speakerId, source, startTime, endTime, text, isEdited) VALUES
                ('m1', 'me', 'mic', 0, 60, '', 0),
                ('m1', 'other', 'system', 0, 1, 'привет', 0),
                ('m1', 'other', 'system', 1, 2, '  ', 1)
                """)
            try db.execute(sql: "INSERT INTO meeting_speakers (meetingId, speakerId) VALUES ('m1', 'me'), ('m1', 'other')")
        }

        try DatabaseManager.migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT text FROM transcript_segments ORDER BY id"),
                           ["привет", "  "], "пустой неотредактированный сегмент удалён, ручная правка осталась")
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT speakerId FROM meeting_speakers"),
                           ["other"], "спикер, державшийся только на пустом сегменте, ушёл из встречи")
        }
    }

    /// no text from ASR means no segments, not one empty row over the file.
    func testEmptyASRResultMakesNoSegments() {
        XCTAssertTrue(TranscriptionService.segments(timings: nil, text: " ", duration: 60).isEmpty)
        XCTAssertTrue(TranscriptionService.segments(timings: [], text: "", duration: 60).isEmpty)
        XCTAssertEqual(TranscriptionService.segments(timings: nil, text: "да", duration: 3).map(\.text), ["да"])
    }

    // MARK: - v26: speaker verdicts in meeting_marks

    /// The column is additive: every earlier mark reads back with no speaker,
    /// and a verdict naming a speaker row that does not exist is refused.
    func testV26_oldMarksReadWithoutSpeaker_verdictNeedsARealSpeaker() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v25-drop-empty-segments")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meetings (id, title, startTime) VALUES ('m1', 'm1', '2026-01-01')")
            try db.execute(sql: """
                INSERT INTO meeting_marks (meetingId, startTime, endTime, track, kind, source)
                VALUES ('m1', 0, 10, 'mic', 'excluded', 'button'), ('m1', 5, 8, 'mic', 'included', 'manual')
                """)
        }

        try DatabaseManager.migrator.migrate(queue)

        let marks = try queue.read { db in try MeetingMark.fetchAll(db) }
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(Set(marks.map(\.kind)), [.excluded, .included])
        XCTAssertTrue(marks.allSatisfy { $0.speakerId == nil })

        XCTAssertThrowsError(try queue.write { db in
            var verdict = MeetingMark(meetingId: "m1", startTime: 0, endTime: 5, kind: .speaker, speakerId: "ghost")
            try verdict.insert(db)
        }, "вердикт на несуществующего спикера падает на внешнем ключе")
    }

    // MARK: - v31: the extracting status is gone

    /// A meeting left in the removed stage still reads, as an unfinished one.
    func testV31_extractingMeetingReadsAsUnfinished() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v30-drop-action-items")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meetings (id, title, startTime, status) VALUES ('m1', 'm1', '2026-01-01', 'extracting')")
        }

        try DatabaseManager.migrator.migrate(queue)

        let meeting = try queue.read { db in try Meeting.fetchOne(db, key: "m1") }
        XCTAssertEqual(meeting?.status, .diarizing)
    }

    // MARK: - v32: dictations awaiting recognition

    /// Dictations from before the column read as settled, not owed a recognition.
    func testV32_oldDictationsAreNotAwaiting() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v31-drop-extracting-status")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dictations (id, createdAt, text, durationSeconds, inserted, audioFileName)
                VALUES ('d1', '2026-01-01', '', 3, 0, 'd1.wav')
                """)
        }

        try DatabaseManager.migrator.migrate(queue)

        let dictation = try queue.read { db in try Dictation.fetchOne(db, key: "d1") }
        XCTAssertEqual(dictation?.awaitingTranscription, false)
    }

    // MARK: - v27: covering index for the listen queue

    /// A voice's speech per meeting is answered from the index alone: a plan
    /// that goes back to the table reads every line with its embedding.
    func testV27_voiceIndexCoversSpeechPerMeeting_andKeepsTheLines() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v26-speaker-verdicts")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meetings (id, title, startTime) VALUES ('m1', 'm1', '2026-01-01')")
            try db.execute(sql: "INSERT INTO speakers (id, nameEn) VALUES ('s1', 'speaker_1')")
            try db.execute(sql: """
                INSERT INTO transcript_segments (meetingId, speakerId, source, startTime, endTime, text)
                VALUES ('m1', 's1', 'system', 0, 4, 'a'), ('m1', 's1', 'system', 5, 7, 'b')
                """)
        }

        try DatabaseManager.migrator.migrate(queue)

        let (plan, seconds) = try queue.read { db in
            let sql = """
                SELECT meetingId, SUM(endTime - startTime), MAX(id) FROM transcript_segments
                WHERE speakerId = 's1' AND isExcluded = 0 GROUP BY meetingId
                """
            return (
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String },
                try Row.fetchOne(db, sql: sql).map { $0[1] as Double }
            )
        }
        XCTAssertEqual(seconds, 6, "реплики на месте")
        XCTAssertTrue(plan.contains { $0.contains("COVERING INDEX idx_segments_voice") }, "план: \(plan)")
    }

    func testForeignKeyIntegrity() async throws {
        let db = try makeTestDB()

        // Insert some data with foreign keys
        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)

        let meeting = makeMeeting()
        let speaker = makeSpeaker(name: "Alice")
        try await meetingRepo.save(meeting)
        try await speakerRepo.save(speaker)
        try await speakerRepo.assignSpeakerToMeeting(meetingId: meeting.id, speakerId: speaker.id, diarizationLabel: nil)
        try await meetingRepo.saveSegments([makeSegment(meetingId: meeting.id, speakerId: speaker.id)])

        // PRAGMA foreign_key_check returns rows for violations — empty means all good
        let violations: [Row] = try await db.reader.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        }
        XCTAssertTrue(violations.isEmpty, "Foreign key integrity check should pass")
    }
    /// A live database records the migrations it ran by name. Renaming,
    /// reordering or dropping one makes GRDB refuse that database or run the
    /// renamed step a second time; new migrations go at the end.
    func testRegisteredMigrationsAreFrozen() {
        XCTAssertEqual(DatabaseManager.migrator.migrations, [
            "v1-create-schema", "v2-phase3-series-tags", "v3-meeting-tasks", "v4-speaker-profile",
            "v5-cleanup-duplicate-speakers", "v6-meeting-description", "v7-cleanup-phantom-speakers",
            "v8-task-timestamp", "v9-cleanup-phantom-speakers", "v10-cleanup-orphaned-speakers",
            "v11-speaker-embedding", "v12-speaker-confirmed-and-name-cleanup", "v13-wespeaker-embedding-v2",
            "v14-speaker-hue", "v15-series-metadata", "v16-segments-speaker-index",
            "v17-segments-speaker-covering-index", "v18-drop-meeting-tasks", "v19-dictations",
            "v20-meeting-marks", "v21-foreign-voice-decision", "v22-speaker-row-per-meeting",
            "v23-reconcile-meeting-speakers", "v24-mark-text", "v25-drop-empty-segments",
            "v26-speaker-verdicts", "v27-segments-voice-index", "v28-library-paths-under-the-new-name",
            "v29-meeting-status-reason", "v30-drop-action-items", "v31-drop-extracting-status",
            "v32-dictation-awaiting-transcription",
        ])
    }

    /// v23 rewrites meeting_speakers across the whole database: a link with no
    /// line behind it goes, a line without a link gets one, and nothing else
    /// moves — no line, no speaker.
    func testV23ReconcileKeepsLinesAndSpeakers() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v22-speaker-row-per-meeting")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meetings (id, title, startTime) VALUES ('m1', 'm1', '2026-01-01')")
            for id in ["talks", "phantom", "unlinked"] {
                try db.execute(sql: "INSERT INTO speakers (id, nameEn, isConfirmed) VALUES (?, ?, 1)", arguments: [id, id])
            }
            for id in ["talks", "phantom"] {
                try db.execute(sql: "INSERT INTO meeting_speakers (meetingId, speakerId, diarizationLabel) VALUES ('m1', ?, ?)",
                               arguments: [id, id])
            }
            for (i, id) in ["talks", "unlinked", "talks"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO transcript_segments (meetingId, speakerId, speakerLabel, source, startTime, endTime, text)
                    VALUES ('m1', ?, ?, 'system', ?, ?, 't')
                    """, arguments: [id, id, Double(i), Double(i) + 1])
            }
        }

        try DatabaseManager.migrator.migrate(queue, upTo: "v23-reconcile-meeting-speakers")

        try queue.read { db in
            let linked = try String.fetchAll(db, sql: "SELECT speakerId FROM meeting_speakers WHERE meetingId = 'm1' ORDER BY speakerId")
            XCTAssertEqual(linked, ["talks", "unlinked"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"), 3, "no line lost")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speakers"), 3, "speakers are not deleted, only unlinked")
        }
    }
}
