import Foundation
import GRDB

struct Tag: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tags"

    var id: String
    var name: String

    init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

struct MeetingTag: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meeting_tags"

    var meetingId: String
    var tagId: String
}
