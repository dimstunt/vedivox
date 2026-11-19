import Foundation
import GRDB

/// Read-only model matching the `speakers` table in the Vedivox database.
package struct Speaker: Identifiable, Decodable, FetchableRecord, Sendable {
    package let id: String
    package let nameEn: String
    package let nameRu: String?
    package let nickname: String?
    package let isMe: Bool
    package let isConfirmed: Bool
    package let createdAt: Date

    package var displayName: String {
        if let ru = nameRu, !ru.isEmpty { return ru }
        if let nick = nickname, !nick.isEmpty { return nick }
        return nameEn
    }
}
