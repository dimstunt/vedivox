import Foundation
import GRDB

/// Storage for dictation history.
///
/// Owns both halves of a dictation record — the row and its audio file — because
/// they have to be trimmed together: retention removes audio and nulls the file
/// name in one step, and a crash between the two would leave a row pointing at a
/// file that no longer exists.
struct DictationRepository {
    private let db: DatabaseManager
    /// Overridable so tests keep their WAVs out of the real dictations folder.
    private let audioRoot: URL?

    init(db: DatabaseManager = .shared, audioRoot: URL? = nil) {
        self.db = db
        self.audioRoot = audioRoot
    }

    // MARK: - Reading

    /// Newest first — the order the history is always shown in.
    func recent(limit: Int = 200) async throws -> [Dictation] {
        try await db.reader.read { db in
            try Dictation
                .order(Dictation.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func find(_ id: String) async throws -> Dictation? {
        try await db.reader.read { db in
            try Dictation.fetchOne(db, key: id)
        }
    }

    /// Dictations saved by a quit or a crash whose recognition is still owed, oldest first.
    func awaitingTranscription() async throws -> [Dictation] {
        try await db.reader.read { db in
            try Dictation
                .filter(Dictation.Columns.awaitingTranscription)
                .order(Dictation.Columns.createdAt)
                .fetchAll(db)
        }
    }

    func count() async throws -> Int {
        try await db.reader.read { db in
            try Dictation.fetchCount(db)
        }
    }

    // MARK: - Writing

    func save(_ dictation: Dictation) async throws {
        try await db.writer.write { db in
            try dictation.save(db)
        }
    }

    /// Replaces the text of an existing record — used after re-transcribing.
    /// Settles a recognition a quit left owed, even with empty text.
    func updateText(_ id: String, text: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE dictations SET text = ?, awaitingTranscription = 0 WHERE id = ?",
                arguments: [text, id]
            )
        }
    }

    /// Deletes a record and its audio.
    func delete(_ id: String) async throws {
        let record = try await find(id)
        if let fileName = record?.audioFileName {
            removeAudioFile(named: fileName)
        }
        _ = try await db.writer.write { db in
            try Dictation.deleteOne(db, key: id)
        }
    }

    // MARK: - Audio

    func audioURL(for dictation: Dictation) -> URL? {
        guard let fileName = dictation.audioFileName else { return nil }
        return try? DatabaseManager.dictationAudioDirectory(root: audioRoot)
            .appendingPathComponent(fileName)
    }

    /// Moves a finished clip into the dictation audio directory and returns the
    /// stored file name.
    func storeAudio(from source: URL, id: String) throws -> String {
        let directory = try DatabaseManager.dictationAudioDirectory(root: audioRoot)
        let fileName = "\(id).\(source.pathExtension.isEmpty ? "wav" : source.pathExtension)"
        let destination = directory.appendingPathComponent(fileName)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        return fileName
    }

    /// Applies the retention policy: deletes audio beyond the limit and clears
    /// the file names of the records it trimmed. Text is never touched.
    ///
    /// Runs after each new dictation, so the folder cannot grow unattended.
    @discardableResult
    func enforceRetention(limit: Int = DictationRetention.defaultAudioLimit) async throws -> Int {
        let all = try await recent(limit: 1000)
        let doomed = DictationRetention.audioToDelete(from: all, limit: limit)
        guard !doomed.isEmpty else { return 0 }

        for record in doomed {
            if let fileName = record.audioFileName {
                removeAudioFile(named: fileName)
            }
        }

        let ids = doomed.map(\.id)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dictations SET audioFileName = NULL
                    WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))
                    """,
                arguments: StatementArguments(ids)
            )
        }
        Log.info("Dictation retention: dropped audio for \(ids.count) record(s), text kept")
        return ids.count
    }

    private func removeAudioFile(named fileName: String) {
        guard let directory = try? DatabaseManager.dictationAudioDirectory(root: audioRoot) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}
