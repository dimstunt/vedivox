import Foundation
import GRDB

actor DatabaseManager {
    static let shared = DatabaseManager()

    private var dbQueue: DatabaseQueue?

    /// Returns the database queue, auto-initializing on first access.
    var db: DatabaseQueue {
        get throws {
            if let dbQueue { return dbQueue }
            try setup()
            return dbQueue!
        }
    }

    // Keep reader/writer as aliases for compatibility
    var reader: DatabaseQueue { get throws { try db } }
    var writer: DatabaseQueue { get throws { try db } }

    private func setup() throws {
        guard dbQueue == nil else { return }

        let dataDirectory = DataDirectory.root

        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        // A test host is the real app: VedivoxTests runs with TEST_HOST=Vedivox.app, so
        // `Vedivox.sqlite` here would be the user's live database. On 2026-08-08
        // that combination — plus the erase-on-schema-change flag that used to
        // live below — wiped 158 meetings and 115k segments the moment a new
        // migration was added and the snapshot tests were run. Tests get their
        // own file now, and the flag is gone.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        let fileName = isRunningTests ? "Vedivox-tests.sqlite" : "Vedivox.sqlite"
        let dbPath = dataDirectory.appendingPathComponent(fileName).path
        if isRunningTests {
            Log.info("DatabaseManager: test host detected — using \(fileName), never the live database")
        }

        var config = Configuration()
        // vedivox-mcp writes too (speaker/segment updates); without a timeout a
        // collision fails outright instead of waiting a few milliseconds.
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            // WAL must be set outside a transaction, prepareDatabase runs before any transaction
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            #if DEBUG
            db.trace { Log.debug("SQL: \($0)") }
            #endif
        }

        let queue = try DatabaseQueue(path: dbPath, configuration: config)

        // Refuse a database written by a newer build, and take a backup before
        // changing anyone's data. Both happen before `migrate`, which is the
        // only ordering that means anything here.
        try DatabaseSafety.update(
            queue,
            migrator: Self.migrator,
            databasePath: dbPath,
            dataDirectory: dataDirectory
        )

        self.dbQueue = queue
    }

    private init() {}

    /// Online backup of the live database into a standalone SQLite file
    /// (Settings → Storage). Safe to run while the app is writing.
    func backup(to url: URL) throws {
        let destination = try DatabaseQueue(path: url.path)
        try db.backup(to: destination)
    }

    #if DEBUG
    init(inMemory: Bool) throws {
        let queue = try DatabaseQueue()
        try Self.migrator.migrate(queue)
        self.dbQueue = queue
    }

    /// A read-only view of a database SNAPSHOT file for offline analysis
    /// (VedivoxBench replay). No migration, no backup, nothing written.
    init(readOnlySnapshot path: String) throws {
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
    }
    #endif

    // MARK: - Migrations

    /// Where v21 finds the legacy «участник» answers. A seam for its test:
    /// `.standard` is one domain for every xctest process on the machine, and
    /// each full migration (any `makeTestDB()`) deletes the key under it.
    nonisolated(unsafe) static var legacyDefaults: UserDefaults = .standard

    /// Not private: `DatabaseSafety` compares the database's applied migrations
    /// against this set, and the tests need to build a migrator that pretends
    /// to be a newer build.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // `eraseDatabaseOnSchemaChange` is deliberately NOT set, in any
        // configuration. It destroyed the live database on 2026-08-08: a debug
        // build (the XCTest host is one) saw the new v19 migration, decided the
        // schema had changed, and erased everything. Migrations here are
        // additive and reviewed; silently recreating the database is never the
        // behaviour we want, not even in debug.

        migrator.registerMigration("v1-create-schema") { db in
            // Meetings
            try db.create(table: "meetings") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("startTime", .datetime).notNull()
                t.column("endTime", .datetime)
                t.column("durationSeconds", .double)
                t.column("language", .text).defaults(to: "ru")
                t.column("calendarEventId", .text)
                t.column("source", .text).defaults(to: "recording")
                t.column("sourceFilePath", .text)
                t.column("micAudioPath", .text)
                t.column("systemAudioPath", .text)
                t.column("status", .text).defaults(to: "recording")
                t.column("createdAt", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            }

            // Speakers
            try db.create(table: "speakers") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("isMe", .boolean).defaults(to: false)
                t.column("createdAt", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            }

            // Transcript segments
            try db.create(table: "transcript_segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull().references("meetings")
                t.column("speakerId", .text).references("speakers")
                t.column("speakerLabel", .text)
                t.column("source", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("text", .text).notNull()
                t.column("originalText", .text)
                t.column("isEdited", .boolean).defaults(to: false)
                t.column("confidence", .double)
            }

            try db.create(
                index: "idx_segments_meeting",
                on: "transcript_segments",
                columns: ["meetingId"]
            )

            // FTS5 for full-text search
            try db.create(virtualTable: "transcript_fts", using: FTS5()) { t in
                t.synchronize(withTable: "transcript_segments")
                t.column("text")
            }

            // Meeting speakers
            try db.create(table: "meeting_speakers") { t in
                t.column("meetingId", .text).notNull().references("meetings")
                t.column("speakerId", .text).notNull().references("speakers")
                t.column("diarizationLabel", .text)
                t.primaryKey(["meetingId", "speakerId"])
            }

            // Action items
            try db.create(table: "action_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull().references("meetings")
                t.column("text", .text).notNull()
                t.column("assignee", .text)
                t.column("assigneeSpeakerId", .text).references("speakers")
                t.column("dueDate", .datetime)
                t.column("status", .text).defaults(to: "open")
                t.column("createdAt", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        migrator.registerMigration("v2-phase3-series-tags") { db in
            try db.create(table: "meeting_series") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("calendarSeriesId", .text)
                t.column("createdAt", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "tags") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
            }

            try db.create(table: "meeting_tags") { t in
                t.column("meetingId", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("tagId", .text).notNull().references("tags", onDelete: .cascade)
                t.primaryKey(["meetingId", "tagId"])
            }

            try db.alter(table: "meetings") { t in
                t.add(column: "seriesId", .text).references("meeting_series")
            }

            try db.create(index: "idx_meetings_series", on: "meetings", columns: ["seriesId"])
        }

        migrator.registerMigration("v3-meeting-tasks") { db in
            try db.create(table: "meeting_tasks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("externalTaskId", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "things")
                t.column("title", .text).notNull()
                t.column("url", .text)
                t.column("createdAt", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(index: "idx_meeting_tasks_meeting", on: "meeting_tasks", columns: ["meetingId"])
            try db.create(
                index: "idx_meeting_tasks_unique",
                on: "meeting_tasks",
                columns: ["meetingId", "externalTaskId", "source"],
                unique: true
            )
        }

        migrator.registerMigration("v4-speaker-profile") { db in
            try db.alter(table: "speakers") { t in
                t.add(column: "nickname", .text)
                t.add(column: "nameRu", .text)
                t.add(column: "nameEn", .text)
            }
        }

        migrator.registerMigration("v5-cleanup-duplicate-speakers") { db in
            // Remove duplicate meeting_speakers with the same diarization label per meeting,
            // keeping one (smallest rowid) for each (meetingId, diarizationLabel) pair.
            try db.execute(sql: """
                DELETE FROM meeting_speakers
                WHERE diarizationLabel IS NOT NULL
                AND rowid NOT IN (
                    SELECT MIN(rowid) FROM meeting_speakers
                    WHERE diarizationLabel IS NOT NULL
                    GROUP BY meetingId, diarizationLabel
                )
                """)

            // Delete speakers not referenced by any meeting or segment.
            try db.execute(sql: """
                DELETE FROM speakers
                WHERE id NOT IN (SELECT DISTINCT speakerId FROM meeting_speakers)
                AND id NOT IN (
                    SELECT DISTINCT speakerId FROM transcript_segments
                    WHERE speakerId IS NOT NULL
                )
                """)
        }

        migrator.registerMigration("v6-meeting-description") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "description", .text)
            }
        }

        migrator.registerMigration("v7-cleanup-phantom-speakers") { db in
            // Delete meeting_speakers links where the speaker has zero segments in that meeting
            try db.execute(sql: """
                DELETE FROM meeting_speakers
                WHERE rowid IN (
                    SELECT ms.rowid FROM meeting_speakers ms
                    LEFT JOIN transcript_segments ts
                        ON ts.speakerId = ms.speakerId AND ts.meetingId = ms.meetingId
                    WHERE ts.id IS NULL
                )
                """)

            // Delete speakers not referenced by any meeting_speakers or segments
            try db.execute(sql: """
                DELETE FROM speakers
                WHERE id NOT IN (SELECT DISTINCT speakerId FROM meeting_speakers)
                AND id NOT IN (
                    SELECT DISTINCT speakerId FROM transcript_segments
                    WHERE speakerId IS NOT NULL
                )
                """)
        }

        migrator.registerMigration("v8-task-timestamp") { db in
            try db.alter(table: "meeting_tasks") { t in
                t.add(column: "timestamp", .double)
            }
        }

        migrator.registerMigration("v9-cleanup-phantom-speakers") { db in
            // Remove meeting_speakers rows where the speaker has no segments in that meeting
            // (accumulated from the reassign-to-existing-speaker bug before it was fixed)
            try db.execute(sql: """
                DELETE FROM meeting_speakers
                WHERE rowid IN (
                    SELECT ms.rowid FROM meeting_speakers ms
                    LEFT JOIN transcript_segments ts
                        ON ts.speakerId = ms.speakerId AND ts.meetingId = ms.meetingId
                    WHERE ts.id IS NULL
                )
                """)

            // Delete speakers no longer referenced by any meeting or segment
            try db.execute(sql: """
                DELETE FROM speakers
                WHERE id NOT IN (SELECT DISTINCT speakerId FROM meeting_speakers)
                AND id NOT IN (
                    SELECT DISTINCT speakerId FROM transcript_segments
                    WHERE speakerId IS NOT NULL
                )
                """)
        }

        migrator.registerMigration("v10-cleanup-orphaned-speakers") { db in
            try db.execute(sql: """
                DELETE FROM meeting_speakers
                WHERE rowid IN (
                    SELECT ms.rowid FROM meeting_speakers ms
                    LEFT JOIN transcript_segments ts
                        ON ts.speakerId = ms.speakerId AND ts.meetingId = ms.meetingId
                    WHERE ts.id IS NULL
                )
                """)

            try db.execute(sql: """
                DELETE FROM speakers
                WHERE id NOT IN (SELECT DISTINCT speakerId FROM meeting_speakers)
                AND id NOT IN (
                    SELECT DISTINCT speakerId FROM transcript_segments
                    WHERE speakerId IS NOT NULL
                )
                """)
        }

        migrator.registerMigration("v11-speaker-embedding") { db in
            try db.alter(table: "speakers") { t in
                t.add(column: "embedding", .blob)
            }
            try db.alter(table: "transcript_segments") { t in
                t.add(column: "embedding", .blob)
            }
        }

        migrator.registerMigration("v12-speaker-confirmed-and-name-cleanup") { db in
            // 1. Add isConfirmed column
            try db.alter(table: "speakers") { t in
                t.add(column: "isConfirmed", .boolean).defaults(to: false)
            }

            // 2. Migrate name data to nameEn/nameRu where those fields are empty
            try db.execute(sql: """
                UPDATE speakers SET nameEn = name
                WHERE nameEn IS NULL AND name NOT GLOB '*[а-яА-ЯёЁ]*'
                """)
            try db.execute(sql: """
                UPDATE speakers SET nameRu = name
                WHERE nameRu IS NULL AND name GLOB '*[а-яА-ЯёЁ]*'
                """)

            // 3. Set isConfirmed for user-interacted speakers
            try db.execute(sql: """
                UPDATE speakers SET isConfirmed = 1
                WHERE isMe = 1
                OR nickname IS NOT NULL
                OR (nameRu IS NOT NULL AND name NOT GLOB '*[а-яА-ЯёЁ]*')
                OR (nameEn IS NOT NULL AND name NOT GLOB 'speaker_[0-9]*')
                OR name NOT GLOB 'speaker_[0-9]*'
                """)

            // 4. Create new table without `name` column, copy data, drop old, rename
            try db.create(table: "speakers_new") { t in
                t.primaryKey("id", .text)
                t.column("nameEn", .text).notNull().defaults(to: "")
                t.column("nameRu", .text)
                t.column("nickname", .text)
                t.column("isMe", .boolean).notNull().defaults(to: false)
                t.column("isConfirmed", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("embedding", .blob)
            }

            try db.execute(sql: """
                INSERT INTO speakers_new (id, nameEn, nameRu, nickname, isMe, isConfirmed, createdAt, embedding)
                SELECT id, COALESCE(nameEn, name), nameRu, nickname, isMe, isConfirmed, createdAt, embedding
                FROM speakers
                """)

            try db.drop(table: "speakers")
            try db.rename(table: "speakers_new", to: "speakers")

            // 5. Ghost link cleanup (one-time)
            try db.execute(sql: """
                DELETE FROM meeting_speakers
                WHERE rowid IN (
                    SELECT ms.rowid FROM meeting_speakers ms
                    LEFT JOIN transcript_segments ts
                        ON ts.speakerId = ms.speakerId AND ts.meetingId = ms.meetingId
                    WHERE ts.id IS NULL
                )
                """)

            try db.execute(sql: """
                DELETE FROM speakers
                WHERE isConfirmed = 0
                AND id NOT IN (SELECT DISTINCT speakerId FROM meeting_speakers)
                AND id NOT IN (
                    SELECT DISTINCT speakerId FROM transcript_segments
                    WHERE speakerId IS NOT NULL
                )
                """)
        }

        migrator.registerMigration("v13-wespeaker-embedding-v2") { db in
            // dual-pool transition to the offline (pyannote/WeSpeaker)
            // diarizer. Both embedders emit 256-dim vectors, so the space of a
            // stored vector is NOT recoverable from the data — it must be tracked:
            //   - speakers.embeddingV2 — canonical in WeSpeaker space
            //   - meetings.diarizer — which diarizer produced this meeting's
            //     segment embeddings ('online'/'offline'; NULL = legacy = online)
            // Idempotent (column-existence check) because the apply tool
            // pre-alters the prod DB before this migration ships in the app.
            if try !db.columns(in: "speakers").contains(where: { $0.name == "embeddingV2" }) {
                try db.alter(table: "speakers") { t in
                    t.add(column: "embeddingV2", .blob)
                }
            }
            if try !db.columns(in: "meetings").contains(where: { $0.name == "diarizer" }) {
                try db.alter(table: "meetings") { t in
                    t.add(column: "diarizer", .text)
                }
            }
        }

        migrator.registerMigration("v14-speaker-hue") { db in
            // persistent per-speaker color. Existing
            // speakers get evenly spread hues (stable order by createdAt so the
            // assignment is deterministic); new speakers get the hue most
            // distant from existing ones via SpeakerHueMath.nextHue.
            try db.alter(table: "speakers") { t in
                t.add(column: "hue", .double)
            }
            let ids = try String.fetchAll(db, sql: "SELECT id FROM speakers ORDER BY createdAt, id")
            let hues = SpeakerHueMath.evenSpread(count: ids.count)
            for (id, hue) in zip(ids, hues) {
                try db.execute(sql: "UPDATE speakers SET hue = ? WHERE id = ?", arguments: [hue, id])
            }
        }

        migrator.registerMigration("v15-series-metadata") { db in
            // series detail page — color, icon, description and the
            // auto-add rule (regex over meeting titles).
            try db.alter(table: "meeting_series") { t in
                t.add(column: "hue", .double)
                t.add(column: "icon", .text)
                t.add(column: "seriesDescription", .text)
                t.add(column: "autoRulePattern", .text)
            }
            let ids = try String.fetchAll(db, sql: "SELECT id FROM meeting_series ORDER BY createdAt, id")
            let hues = SpeakerHueMath.evenSpread(count: ids.count)
            for (id, hue) in zip(ids, hues) {
                try db.execute(sql: "UPDATE meeting_series SET hue = ? WHERE id = ?", arguments: [hue, id])
            }
        }

        migrator.registerMigration("v16-segments-speaker-index") { db in
            // Speakers page aggregates speaking time per speaker over ~100k
            // segments; without this index every per-speaker lookup scans the
            // whole table (measured 2.25s → 0.04s on the page query).
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_segments_speaker
                ON transcript_segments(speakerId)
                """)
        }

        migrator.registerMigration("v17-segments-speaker-covering-index") { db in
            // The v16 index still dereferences every row for endTime/startTime,
            // so a cold Speakers-page open pays random IO across the whole
            // segments table (measured 0.94s cold / 0.23s warm at 94k rows).
            // A covering index answers SUM(endTime - startTime) GROUP BY
            // speakerId from the index alone.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_segments_speaker_times
                ON transcript_segments(speakerId, endTime, startTime)
                """)
            try db.execute(sql: "DROP INDEX IF EXISTS idx_segments_speaker")
        }

        migrator.registerMigration("v18-drop-meeting-tasks") { db in
            // Task linking (meeting_tasks + MCP link/unlink tools) was removed:
            // user stopped using in-app tasks (2026-07-11). Dropping the table
            // also drops its indexes (idx_meeting_tasks_meeting,
            // idx_meeting_tasks_unique).
            try db.execute(sql: "DROP TABLE IF EXISTS meeting_tasks")
        }

        migrator.registerMigration("v19-dictations") { db in
            // Dictation history.
            // Its own table rather than a row in `meetings`: a dictation has no
            // speakers, no series and no diarization, and living in `meetings`
            // would drop it into meeting lists and the processing pipeline.
            try db.create(table: "dictations") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull()
                t.column("text", .text).notNull()
                t.column("durationSeconds", .double).notNull()
                t.column("targetApp", .text)
                t.column("inserted", .boolean).notNull()
                // Null once retention has removed the audio — the text stays.
                t.column("audioFileName", .text)
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_dictations_created
                ON dictations(createdAt DESC)
                """)
        }

        migrator.registerMigration("v20-meeting-marks") { db in
            // Exclusion marks: time
            // intervals of one track marked "not for the transcript". Their own
            // table, keyed by meeting + time, so they survive reprocess —
            // transcript_segments rows are deleted and recreated with new ids.
            // endTime is NULL while a recording-time button interval is open.
            try db.create(table: "meeting_marks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("startTime", .double).notNull()
                t.column("endTime", .double)
                t.column("track", .text).notNull().defaults(to: "mic")
                t.column("kind", .text).notNull().defaults(to: "excluded")
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(index: "idx_meeting_marks_meeting", on: "meeting_marks", columns: ["meetingId"])

            // Derived cache of the projection rule (D2). Truth stays in
            // meeting_marks; this column only keeps the hot read path free of
            // joins. Recomputed by MarkRepository.reproject.
            try db.alter(table: "transcript_segments") { t in
                t.add(column: "isExcluded", .boolean).notNull().defaults(to: false)
            }

            // Per-meeting "several people at the mic" mode (D8): consumed at
            // processing time, not capture time, so it can be flipped after
            // recording and applied by reprocess.
            try db.alter(table: "meetings") { t in
                t.add(column: "micMultiSpeaker", .boolean).notNull().defaults(to: false)
            }
        }

        // Foreign voices on the mic track (`foreign-voices-on-mic`, решение 6+8).
        // The mode column stops being about processing and becomes the decision
        // itself, so it is renamed along with its meaning and gains the two
        // states a boolean could not hold: «не решено» and «скрыто».
        migrator.registerMigration("v21-foreign-voice-decision") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "foreignVoiceDecision", .text)
                    .notNull().defaults(to: ForeignVoiceDecision.undecided.rawValue)
            }
            // «Несколько людей на микрофоне» meant «показывай их» — that is
            // exactly «оставлено».
            try db.execute(
                sql: "UPDATE meetings SET foreignVoiceDecision = ? WHERE micMultiSpeaker = 1",
                arguments: [ForeignVoiceDecision.kept.rawValue]
            )
            // The old «участник» answers lived in a UserDefaults list, which
            // could say «человек ответил» but never «ещё не спрашивали». Move
            // them over and stop reading the list.
            let dismissed = legacyDefaults
                .stringArray(forKey: "unknownPromptDismissedMeetings") ?? []
            for meetingId in dismissed {
                try db.execute(
                    sql: "UPDATE meetings SET foreignVoiceDecision = ? WHERE id = ?",
                    arguments: [ForeignVoiceDecision.kept.rawValue, meetingId]
                )
            }
            if !dismissed.isEmpty {
                Log.info("Migration v21: carried \(dismissed.count) dismissed prompt(s) over to «kept»")
            }
            legacyDefaults.removeObject(forKey: "unknownPromptDismissedMeetings")

            try db.alter(table: "meetings") { t in
                t.drop(column: "micMultiSpeaker")
            }
        }

        // One speaker row per mint (speaker-row-per-mint): `speaker_N` is a
        // per-meeting slot name, but `findOrCreateSpeaker` used to bind every
        // mint to one shared row by name — one speaker_1 row collected 72
        // meetings of different people. Split the accumulated shared auto rows
        // so each belongs to exactly one meeting. Canonicals of split rows are
        // voided: they were means over dozens of voices.
        migrator.registerMigration("v22-speaker-row-per-meeting") { db in
            let sharedRows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.nameEn, s.hue FROM speakers s
                WHERE s.isConfirmed = 0 AND s.nameEn GLOB 'speaker_[0-9]*'
                """)
            var rowsSplit = 0, newRows = 0, segmentsMoved = 0, linksMoved = 0
            for row in sharedRows {
                let speakerId: String = row["id"]
                let nameEn: String = row["nameEn"]
                let hue: Double? = row["hue"]
                let meetingIds = try String.fetchAll(db, sql: """
                    SELECT u.meetingId FROM (
                        SELECT meetingId FROM meeting_speakers WHERE speakerId = ?1
                        UNION
                        SELECT meetingId FROM transcript_segments WHERE speakerId = ?1
                    ) u JOIN meetings m ON m.id = u.meetingId
                    ORDER BY m.startTime, m.id
                    """, arguments: [speakerId])
                guard meetingIds.count > 1 else { continue }
                rowsSplit += 1
                // The original stays on the earliest meeting; every other
                // meeting gets its own row with the same label and hue, so
                // nothing changes visually inside any meeting.
                for meetingId in meetingIds.dropFirst() {
                    let newId = UUID().uuidString
                    try db.execute(sql: """
                        INSERT INTO speakers (id, nameEn, isMe, isConfirmed, hue)
                        VALUES (?, ?, 0, 0, ?)
                        """, arguments: [newId, nameEn, hue])
                    newRows += 1
                    try db.execute(sql: """
                        UPDATE transcript_segments SET speakerId = ?
                        WHERE speakerId = ? AND meetingId = ?
                        """, arguments: [newId, speakerId, meetingId])
                    segmentsMoved += db.changesCount
                    try db.execute(sql: """
                        UPDATE meeting_speakers SET speakerId = ?
                        WHERE speakerId = ? AND meetingId = ?
                        """, arguments: [newId, speakerId, meetingId])
                    linksMoved += db.changesCount
                    // Drifted data guard: a segments-only meeting (link row
                    // missing) still gets its per-meeting link.
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO meeting_speakers (meetingId, speakerId, diarizationLabel)
                        SELECT ?1, ?2, speakerLabel FROM transcript_segments
                        WHERE speakerId = ?2 AND meetingId = ?1 LIMIT 1
                        """, arguments: [meetingId, newId])
                }
                // The shared canonical was a mean over dozens of voices — void
                // it on the row that stays behind too.
                try db.execute(
                    sql: "UPDATE speakers SET embedding = NULL, embeddingV2 = NULL WHERE id = ?",
                    arguments: [speakerId]
                )
            }
            if rowsSplit > 0 {
                Log.info("Migration v22: split \(rowsSplit) shared auto row(s) into \(newRows) new per-meeting row(s), moved \(segmentsMoved) segment(s) and \(linksMoved) link(s)")
            }
        }

        // Links in meeting_speakers outlived the segments they described:
        // reassigning a speaker's last segment left them listed in the meeting
        // (15 links on 2026-09-02), and one segment had no link at all.
        // Reassignment paths keep the table in sync from here on
        // (MeetingRepository.reconcileMeetingSpeakers); this repairs the past.
        migrator.registerMigration("v23-reconcile-meeting-speakers", migrate: reconcileAllMeetingSpeakers)

        // a dictation made during a meeting is a mark on the mic
        // track that carries the inserted text, shown in the transcript.
        migrator.registerMigration("v24-mark-text") { db in
            try db.alter(table: "meeting_marks") { t in
                t.add(column: "text", .text)
            }
        }

        // an empty ASR result used to be saved as one segment with
        // no text over the whole file — clutter in the transcript, the CLI and
        // MCP. Hand-edited rows stay: emptying a segment was the user's call.
        migrator.registerMigration("v25-drop-empty-segments") { db in
            try db.execute(sql: "DELETE FROM transcript_segments WHERE trim(text) = '' AND isEdited = 0")
            try reconcileAllMeetingSpeakers(db)
        }

        // listen-queue § 3: a verdict "speech of this track in this interval is
        // that speaker" is a mark too, so trim/split/merge carry it by time and
        // it survives reprocess. NULL on every visibility mark; the cascade drops
        // the verdicts of a deleted speaker row.
        migrator.registerMigration("v26-speaker-verdicts") { db in
            try db.alter(table: "meeting_marks") { t in
                t.add(column: "speakerId", .text).references("speakers", onDelete: .cascade)
            }
        }

        // The listen queue sums the non-excluded speech of every anonymous voice
        // and looks for a person's lines meeting by meeting. Without this index
        // both read whole rows, each with its 1 KB embedding (measured
        // on 381 meetings and 288k lines: the aggregate 130–900 ms → 8 ms, a
        // candidate's sample 8 ms → 0.2 ms). Covering: the index alone answers.
        migrator.registerMigration("v27-segments-voice-index") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_segments_voice
                ON transcript_segments(speakerId, meetingId, isExcluded, startTime, endTime)
                """)
        }

        // The library of someone who used the app under its old name moved to
        // another directory (DataDirectoryMigration), and the absolute paths
        // stored here follow it. In any other database nothing matches.
        migrator.registerMigration("v28-library-paths-under-the-new-name") { db in
            try DataDirectoryMigration.rewriteStoredPaths(
                db,
                from: DataDirectoryMigration.legacyProduction.path,
                to: DataDirectory.production.path
            )
        }

        // Why a meeting is `needsAttention` or `error`, in the codes the
        // pipeline logs (MeetingStatusReason); NULL for meetings processed
        // before it was kept. Added only: the lab mirror reads this table.
        migrator.registerMigration("v29-meeting-status-reason") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "statusReason", .text)
            }
        }

        migrator.registerMigration("v30-drop-action-items") { db in
            // Action items were removed from the app (2026-11-18): nothing
            // wrote the table, the inspector only showed what tests put there.
            try db.execute(sql: "DROP TABLE IF EXISTS action_items")
        }

        migrator.registerMigration("v31-drop-extracting-status") { db in
            // The action-items stage went with action items (2026-11-18). A
            // row left in it was an unfinished meeting: it stays one, so crash
            // recovery picks it up as before instead of failing to decode.
            try db.execute(sql: "UPDATE meetings SET status = 'diarizing' WHERE status = 'extracting'")
        }

        migrator.registerMigration("v32-dictation-awaiting-transcription") { db in
            // A dictation cut short by a quit or a crash keeps its audio and
            // waits for recognition at the next launch.
            try db.alter(table: "dictations") { t in
                t.add(column: "awaitingTranscription", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }

    /// Drops meeting_speakers links with no segment behind them and adds the
    /// missing ones, across the whole database.
    private static func reconcileAllMeetingSpeakers(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM meeting_speakers
            WHERE rowid IN (
                SELECT ms.rowid FROM meeting_speakers ms
                LEFT JOIN transcript_segments ts
                    ON ts.speakerId = ms.speakerId AND ts.meetingId = ms.meetingId
                WHERE ts.id IS NULL
            )
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO meeting_speakers (meetingId, speakerId, diarizationLabel)
            SELECT DISTINCT meetingId, speakerId, speakerLabel FROM transcript_segments
            WHERE speakerId IS NOT NULL
            """)
    }

    // MARK: - Audio Directory

    /// Per-meeting working/audio directory.
    ///
    /// Production resolves to `<data directory>/audio/<meetingId>/`.
    /// Pass `root` to redirect everything under a different base — used by the
    /// scenario benchmark to keep intermediate WAVs out of the real audio folder.
    /// `root` stands in for the `.../Vedivox/audio` directory: the meeting dir becomes
    /// `<root>/<meetingId>/`.
    /// Directory holding dictation audio.
    ///
    /// Separate from the per-meeting folders: dictations are not meetings, and
    /// keeping them apart means retention can sweep this directory without ever
    /// looking at meeting recordings.
    ///
    /// Production resolves to `<data directory>/dictations/`.
    static func dictationAudioDirectory(root: URL? = nil) throws -> URL {
        let directory = root ?? DataDirectory.dictations
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func audioDirectory(for meetingId: String, root: URL? = nil) throws -> URL {
        let audioDir = audioDirectoryURL(for: meetingId, root: root)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        return audioDir
    }

    /// Same path as `audioDirectory(for:root:)` but WITHOUT creating anything.
    ///
    /// Deletion must not go through the creating variant: it would materialize
    /// the very directory it is about to throw away.
    static func audioDirectoryURL(for meetingId: String, root: URL? = nil) -> URL {
        let base = root ?? DataDirectory.audio
        return base.appendingPathComponent(meetingId, isDirectory: true)
    }

    /// Move a meeting's audio directory to the system Trash.
    ///
    /// Deliberately NOT `removeItem`: a misclick on delete used to be
    /// unrecoverable (a 3h recording died to a stray Cmd+⌫). The
    /// Trash makes the mistake reversible by hand, which no amount of
    /// confirmation dialogs can guarantee on its own.
    ///
    /// Returns the resulting URL inside the Trash, or `nil` when there was no
    /// directory to move.
    @discardableResult
    static func trashAudioDirectory(for meetingId: String, root: URL? = nil) throws -> URL? {
        let audioDir = audioDirectoryURL(for: meetingId, root: root)
        guard FileManager.default.fileExists(atPath: audioDir.path) else { return nil }

        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: audioDir, resultingItemURL: &trashedURL)
        return trashedURL as URL?
    }
}
