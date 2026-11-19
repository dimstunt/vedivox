import Foundation
import GRDB

/// The rows a speaker merge or rename can touch, taken before it runs, so
/// Edit → Undo can put them back (a wrong merge used to be final).
struct SpeakerUndo: Sendable {
    enum UndoError: Error, LocalizedError {
        case dataChanged

        var errorDescription: String? {
            "the speakers or their meetings changed since (reprocessed or edited), so this speaker change can no longer be undone"
        }
    }

    struct SegmentSpeaker: Sendable, Equatable {
        let id: Int64
        let speakerId: String?
        let speakerLabel: String?
    }

    let meetingIds: [String]
    /// Records the change edits or deletes: restored row for row, canonicals included.
    let changedSpeakerIds: Set<String>
    /// Every record the snapshot refers to, so links and lines have someone to point at.
    let speakers: [Speaker]
    /// `embeddingV2` per record of `speakers`: the column is not in `Speaker`, so `save` would not put it back.
    let canonicalsV2: [String: Data]
    let speakerIdsBefore: Set<String>
    let segments: [SegmentSpeaker]
    let links: [MeetingSpeaker]
    let marks: [MeetingMark]
    /// What the change left, see `sealed`; nil on a snapshot that was not sealed.
    private(set) var outcome: [[DatabaseValue]]?

    /// `speakerIds`: records whose lines the change moves or relabels — their
    /// meetings are taken in with `meetingIds`. `rows`: records that only gain
    /// lines (a merge target, the owner): their row is restored, their other
    /// meetings are left out of the snapshot.
    static func capture(
        speakerIds: [String], rows: [String] = [], meetingIds: [String] = [], db: DatabaseManager = .shared
    ) async throws -> SpeakerUndo {
        try await db.reader.read { db in
            let sph = databaseQuestionMarks(count: speakerIds.count)
            let theirs = try String.fetchAll(db, sql: """
                SELECT meetingId FROM meeting_speakers WHERE speakerId IN (\(sph))
                UNION
                SELECT meetingId FROM transcript_segments WHERE speakerId IN (\(sph))
                """, arguments: StatementArguments(speakerIds + speakerIds))
            let meetings = Array(Set(meetingIds + theirs))
            let mph = databaseQuestionMarks(count: meetings.count)
            let segments = try Row.fetchAll(db, sql: """
                SELECT id, speakerId, speakerLabel FROM transcript_segments WHERE meetingId IN (\(mph))
                """, arguments: StatementArguments(meetings))
                .map { SegmentSpeaker(id: $0["id"], speakerId: $0["speakerId"], speakerLabel: $0["speakerLabel"]) }
            let links = try MeetingSpeaker.fetchAll(
                db, sql: "SELECT * FROM meeting_speakers WHERE meetingId IN (\(mph))", arguments: StatementArguments(meetings)
            )
            let referenced = Set(speakerIds + rows + segments.compactMap(\.speakerId) + links.map(\.speakerId))
            let marks = try MeetingMark.fetchAll(db, sql: """
                SELECT * FROM meeting_marks
                WHERE speakerId IS NOT NULL AND (meetingId IN (\(mph)) OR speakerId IN (\(sph)))
                """, arguments: StatementArguments(meetings + speakerIds))
            let ids = Array(referenced)
            let v2 = try Row.fetchAll(db, sql: """
                SELECT id, embeddingV2 FROM speakers WHERE embeddingV2 IS NOT NULL AND id IN (\(databaseQuestionMarks(count: ids.count)))
                """, arguments: StatementArguments(ids))
            return SpeakerUndo(
                meetingIds: meetings,
                changedSpeakerIds: Set(speakerIds + rows),
                speakers: try Speaker.fetchAll(db, keys: ids),
                canonicalsV2: Dictionary(uniqueKeysWithValues: v2.map { ($0["id"] as String, $0["embeddingV2"] as Data) }),
                speakerIdsBefore: Set(try String.fetchAll(db, sql: "SELECT id FROM speakers")),
                segments: segments,
                links: links,
                marks: marks
            )
        }
    }

    /// Taken right after the change. `restore` then refuses once anything else
    /// has touched the same rows: a speaker deleted, the owner mark moved, a
    /// line reassigned by hand — putting the snapshot back would undo that too.
    func sealed(db: DatabaseManager = .shared) async throws -> SpeakerUndo {
        var copy = self
        copy.outcome = try await db.reader.read { try identity($0) }
        return copy
    }

    /// Who holds which line of the snapshot's meetings, who those people are
    /// (names and the owner mark, not their voices) and the verdicts there.
    private func identity(_ db: Database) throws -> [[DatabaseValue]] {
        let mph = databaseQuestionMarks(count: meetingIds.count)
        let changed = Array(changedSpeakerIds)
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, speakerId, speakerLabel FROM transcript_segments WHERE meetingId IN (\(mph)) ORDER BY id
            """, arguments: StatementArguments(meetingIds))
            + Row.fetchAll(db, sql: """
            SELECT id, nameEn, nameRu, nickname, isMe FROM speakers
            WHERE id IN (\(databaseQuestionMarks(count: changed.count)))
               OR id IN (SELECT speakerId FROM transcript_segments WHERE meetingId IN (\(mph)))
            ORDER BY id
            """, arguments: StatementArguments(changed + meetingIds))
            + Row.fetchAll(db, sql: """
            SELECT id, speakerId FROM meeting_marks WHERE speakerId IS NOT NULL AND meetingId IN (\(mph)) ORDER BY id
            """, arguments: StatementArguments(meetingIds))
        return rows.map { Array($0.databaseValues) }
    }

    /// Puts the rows back in one transaction. Refuses when the meetings'
    /// segments are no longer the same rows (a reprocess replaced them), or
    /// when a sealed snapshot no longer finds what its change left.
    func restore(db: DatabaseManager = .shared) async throws {
        let toRecalc: [String] = try await db.writer.write { db in
            if let outcome, try identity(db) != outcome { throw UndoError.dataChanged }
            let mph = databaseQuestionMarks(count: meetingIds.count)
            let now = try Row.fetchAll(db, sql: """
                SELECT id, speakerId, speakerLabel FROM transcript_segments WHERE meetingId IN (\(mph))
                """, arguments: StatementArguments(meetingIds))
                .map { SegmentSpeaker(id: $0["id"], speakerId: $0["speakerId"], speakerLabel: $0["speakerLabel"]) }
            guard Set(now.map(\.id)) == Set(segments.map(\.id)) else { throw UndoError.dataChanged }

            // Records whose lines move back: their canonical follows the voice set.
            let before = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.speakerId) })
            var moved: Set<String> = []
            for seg in now where seg.speakerId != before[seg.id] ?? nil {
                if let id = seg.speakerId { moved.insert(id) }
                if let id = before[seg.id] ?? nil { moved.insert(id) }
            }
            let linkedNow = try String.fetchAll(
                db, sql: "SELECT speakerId FROM meeting_speakers WHERE meetingId IN (\(mph))",
                arguments: StatementArguments(meetingIds)
            )

            for speaker in speakers {
                if changedSpeakerIds.contains(speaker.id) {
                    try speaker.save(db)
                } else {
                    try speaker.insert(db, onConflict: .ignore)
                    guard db.changesCount > 0 else { continue }
                }
                try db.execute(
                    sql: "UPDATE speakers SET embeddingV2 = ? WHERE id = ?", arguments: [canonicalsV2[speaker.id], speaker.id]
                )
            }
            for seg in segments {
                try db.execute(
                    sql: "UPDATE transcript_segments SET speakerId = ?, speakerLabel = ? WHERE id = ?",
                    arguments: [seg.speakerId, seg.speakerLabel, seg.id]
                )
            }
            try db.execute(
                sql: "DELETE FROM meeting_speakers WHERE meetingId IN (\(mph))", arguments: StatementArguments(meetingIds)
            )
            for link in links { try link.insert(db) }
            for mark in marks {
                var mark = mark
                try mark.save(db)
            }

            // Records the change minted go with it, once nothing points at them.
            let minted = Set(linkedNow + moved).subtracting(speakerIdsBefore)
            for id in minted {
                try db.execute(sql: """
                    DELETE FROM speakers WHERE id = ?
                    AND id NOT IN (SELECT speakerId FROM meeting_speakers)
                    AND id NOT IN (SELECT speakerId FROM transcript_segments WHERE speakerId IS NOT NULL)
                    AND id NOT IN (SELECT speakerId FROM meeting_marks WHERE speakerId IS NOT NULL)
                    """, arguments: [id])
            }
            return Array(moved.subtracting(changedSpeakerIds).subtracting(minted))
        }
        let repo = SpeakerRepository(db: db)
        for id in toRecalc {
            do {
                try await repo.recalculateEmbedding(speakerId: id)
            } catch {
                Log.error("SpeakerUndo: recalculateEmbedding for \(id) failed: \(error)")
            }
        }
    }
}

@MainActor
extension UndoManager {
    /// One speaker change on Edit → Undo (⌘Z), named in the menu.
    /// Undo only: putting a wrong merge back is the need, redo is not.
    /// Call right after the change: the snapshot is sealed here.
    func registerSpeakerUndo(
        _ undo: SpeakerUndo, named name: String, db: DatabaseManager = .shared,
        then reload: @escaping @MainActor (_ failure: String?) async -> Void
    ) async {
        let sealed: SpeakerUndo
        do {
            sealed = try await undo.sealed(db: db)
        } catch {
            // An undo that could not tell a later change apart is not offered.
            Log.error("Undo \(name) not offered: \(error)")
            return
        }
        registerUndo(withTarget: SpeakerUndoTarget.shared) { _ in
            Task { @MainActor in
                var failure: String?
                do {
                    try await sealed.restore(db: db)
                } catch {
                    Log.error("Undo \(name) failed: \(error)")
                    failure = "Could not undo \(name.lowercased()): \(error.localizedDescription)"
                }
                await reload(failure)
            }
        }
        setActionName(name)
    }
}

/// UndoManager wants an object to file actions under.
private final class SpeakerUndoTarget: Sendable {
    static let shared = SpeakerUndoTarget()
}
