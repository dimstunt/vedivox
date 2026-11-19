import Foundation
import GRDB

/// Read-only model matching the `meeting_series` table in the Vedivox database.
package struct MeetingSeries: Identifiable, Decodable, FetchableRecord, Sendable {
    package let id: String
    package let name: String
    package let calendarSeriesId: String?
    package let createdAt: Date
}
