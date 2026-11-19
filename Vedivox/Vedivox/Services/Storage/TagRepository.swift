import Foundation
import GRDB

struct TagRepository {
    private let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    func all() async throws -> [Tag] {
        try await db.reader.read { db in
            try Tag.order(Column("name").asc).fetchAll(db)
        }
    }

    func save(_ tag: Tag) async throws {
        try await db.writer.write { db in
            try tag.save(db)
        }
    }

    func addTagToMeeting(tagId: String, meetingId: String) async throws {
        try await db.writer.write { db in
            let mt = MeetingTag(meetingId: meetingId, tagId: tagId)
            try mt.insert(db)
        }
    }

    func removeTagFromMeeting(tagId: String, meetingId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM meeting_tags WHERE meetingId = ? AND tagId = ?",
                arguments: [meetingId, tagId]
            )
        }
    }

    func tagsForMeeting(_ meetingId: String) async throws -> [Tag] {
        try await db.reader.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT tags.* FROM tags
                JOIN meeting_tags ON meeting_tags.tagId = tags.id
                WHERE meeting_tags.meetingId = ?
                ORDER BY tags.name
                """, arguments: [meetingId])
        }
    }
}
