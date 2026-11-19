import Foundation
import GRDB
@testable import VedivoxCLIKit
@testable import VedivoxMCPLib

/// Tests must never reach the user's running Vedivox. The real client is swapped
/// for a refusal before the first database or stub is made, so a test that
/// forgets to stub the app fails instead of sending its command to the live
/// socket (one did: `update_meeting` for a made-up id, 2026-11-09).
let appIsOffLimits: Void = {
    AppCommandDispatch.run = { request in
        throw AppCommandError.notReachable("a test sent \(request.command) without stubbing the app")
    }
    AppCommandDispatch.runIfServing = { request in
        throw AppCommandError.notReachable("a test sent \(request.command) without stubbing the app")
    }
    CLIRuntime.sendLongCommand = { try AppCommandDispatch.run($0) }
}()

// Disambiguate our DatabaseReader from GRDB's DatabaseReader protocol
typealias DatabaseReader = VedivoxMCPLib.DatabaseReader

// MARK: - In-Memory Test Database

/// Creates an in-memory DatabaseReader with the full Vedivox schema (v1-v6).
func makeTestDB() throws -> DatabaseReader {
    _ = appIsOffLimits
    let queue = try DatabaseQueue(configuration: {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return config
    }())

    try queue.write { db in
        // v1: Core schema
        try db.execute(sql: """
            CREATE TABLE meetings (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                startTime DATETIME NOT NULL,
                endTime DATETIME,
                durationSeconds DOUBLE,
                language TEXT DEFAULT 'ru',
                calendarEventId TEXT,
                source TEXT DEFAULT 'recording',
                sourceFilePath TEXT,
                micAudioPath TEXT,
                systemAudioPath TEXT,
                status TEXT DEFAULT 'recording',
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)

        try db.execute(sql: """
            CREATE TABLE speakers (
                id TEXT PRIMARY KEY,
                nameEn TEXT NOT NULL DEFAULT '',
                nameRu TEXT,
                nickname TEXT,
                isMe BOOLEAN DEFAULT false,
                isConfirmed BOOLEAN NOT NULL DEFAULT false,
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP,
                embedding BLOB
            )
            """)

        try db.execute(sql: """
            CREATE TABLE transcript_segments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meetingId TEXT NOT NULL REFERENCES meetings,
                speakerId TEXT REFERENCES speakers,
                speakerLabel TEXT,
                source TEXT NOT NULL,
                startTime DOUBLE NOT NULL,
                endTime DOUBLE NOT NULL,
                text TEXT NOT NULL,
                originalText TEXT,
                isEdited BOOLEAN DEFAULT false,
                confidence DOUBLE
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_segments_meeting ON transcript_segments(meetingId)")

        try db.execute(sql: """
            CREATE VIRTUAL TABLE transcript_fts USING FTS5(
                text,
                content='transcript_segments',
                content_rowid='id'
            )
            """)

        try db.execute(sql: """
            CREATE TABLE meeting_speakers (
                meetingId TEXT NOT NULL REFERENCES meetings,
                speakerId TEXT NOT NULL REFERENCES speakers,
                diarizationLabel TEXT,
                PRIMARY KEY (meetingId, speakerId)
            )
            """)

        // v2: Series & tags
        try db.execute(sql: """
            CREATE TABLE meeting_series (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                calendarSeriesId TEXT,
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)
        try db.execute(sql: "ALTER TABLE meetings ADD COLUMN seriesId TEXT REFERENCES meeting_series")
        try db.execute(sql: "CREATE INDEX idx_meetings_series ON meetings(seriesId)")

        try db.execute(sql: """
            CREATE TABLE tags (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE
            )
            """)
        try db.execute(sql: """
            CREATE TABLE meeting_tags (
                meetingId TEXT NOT NULL REFERENCES meetings ON DELETE CASCADE,
                tagId TEXT NOT NULL REFERENCES tags ON DELETE CASCADE,
                PRIMARY KEY (meetingId, tagId)
            )
            """)

        // v6: Meeting description
        try db.execute(sql: "ALTER TABLE meetings ADD COLUMN description TEXT")
        // v29
        try db.execute(sql: "ALTER TABLE meetings ADD COLUMN statusReason TEXT")

        // v20: Exclusion marks; v21 replaced its micMultiSpeaker flag with foreignVoiceDecision
        try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN isExcluded BOOLEAN NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE meetings ADD COLUMN foreignVoiceDecision TEXT NOT NULL DEFAULT 'undecided'")
        try db.execute(sql: """
            CREATE TABLE meeting_marks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meetingId TEXT NOT NULL REFERENCES meetings ON DELETE CASCADE,
                startTime DOUBLE NOT NULL,
                endTime DOUBLE,
                track TEXT NOT NULL DEFAULT 'mic',
                kind TEXT NOT NULL DEFAULT 'excluded',
                source TEXT NOT NULL DEFAULT 'manual',
                createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                speakerId TEXT REFERENCES speakers(id) ON DELETE CASCADE
            )
            """)
    }

    return DatabaseReader(queue: queue)
}

// MARK: - FTS Sync Trigger

/// Inserts FTS index entries after inserting segments into the test DB.
func syncFTS(db: DatabaseReader) throws {
    try db.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO transcript_fts(transcript_fts) VALUES('rebuild')
            """)
    }
}

// MARK: - Factory Helpers

func makeMeetingId() -> String {
    UUID().uuidString
}

func makeSpeakerId() -> String {
    UUID().uuidString
}

func makeSeriesId() -> String {
    UUID().uuidString
}

// MARK: - Insert Helpers

func insertMeeting(
    db: DatabaseReader,
    id: String = UUID().uuidString,
    title: String = "Test Meeting",
    startTime: Date = Date(),
    endTime: Date? = nil,
    durationSeconds: Double? = 3600,
    language: String = "ru",
    source: String = "recording",
    status: String = "done",
    description: String? = nil,
    seriesId: String? = nil,
    statusReason: String? = nil
) throws -> String {
    try db.dbQueue.write { dbConn in
        try dbConn.execute(
            sql: """
                INSERT INTO meetings (id, title, startTime, endTime, durationSeconds, language, source, status, description, seriesId, statusReason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, title, startTime, endTime, durationSeconds, language, source, status, description, seriesId, statusReason]
        )
    }
    return id
}

func insertSpeaker(
    db: DatabaseReader,
    id: String = UUID().uuidString,
    name: String = "Speaker",
    nickname: String? = nil,
    nameRu: String? = nil,
    isMe: Bool = false
) throws -> String {
    try db.dbQueue.write { dbConn in
        try dbConn.execute(
            sql: """
                INSERT INTO speakers (id, nameEn, nickname, nameRu, isMe)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [id, name, nickname, nameRu, isMe]
        )
    }
    return id
}

func insertMeetingSpeaker(
    db: DatabaseReader,
    meetingId: String,
    speakerId: String,
    diarizationLabel: String? = nil
) throws {
    try db.dbQueue.write { dbConn in
        try dbConn.execute(
            sql: "INSERT INTO meeting_speakers (meetingId, speakerId, diarizationLabel) VALUES (?, ?, ?)",
            arguments: [meetingId, speakerId, diarizationLabel]
        )
    }
}

func insertSegment(
    db: DatabaseReader,
    meetingId: String,
    speakerId: String? = nil,
    speakerLabel: String? = nil,
    source: String = "whisper",
    startTime: Double = 0.0,
    endTime: Double = 5.0,
    text: String = "Hello world",
    confidence: Double? = 0.95,
    isExcluded: Bool = false
) throws -> Int64 {
    try db.dbQueue.write { dbConn in
        try dbConn.execute(
            sql: """
                INSERT INTO transcript_segments (meetingId, speakerId, speakerLabel, source, startTime, endTime, text, confidence, isExcluded)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [meetingId, speakerId, speakerLabel, source, startTime, endTime, text, confidence, isExcluded]
        )
        return dbConn.lastInsertedRowID
    }
}

func insertMark(
    db: DatabaseReader,
    meetingId: String,
    startTime: Double,
    endTime: Double?,
    track: String = "mic",
    kind: String = "excluded",
    source: String = "manual",
    speakerId: String? = nil
) throws -> Int64 {
    try db.dbQueue.write { dbConn in
        try dbConn.execute(
            sql: """
                INSERT INTO meeting_marks (meetingId, startTime, endTime, track, kind, source, speakerId)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [meetingId, startTime, endTime, track, kind, source, speakerId]
        )
        return dbConn.lastInsertedRowID
    }
}

func insertSeries(
    db: DatabaseReader,
    id: String = UUID().uuidString,
    name: String = "Test Series"
) throws -> String {
    try db.dbQueue.write { dbConn in
        try dbConn.execute(
            sql: "INSERT INTO meeting_series (id, name) VALUES (?, ?)",
            arguments: [id, name]
        )
    }
    return id
}
