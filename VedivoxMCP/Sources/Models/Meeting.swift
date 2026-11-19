import Foundation
import GRDB

/// Read-only model matching the `meetings` table in the Vedivox database.
package struct Meeting: Identifiable, Decodable, FetchableRecord, Sendable {
    package let id: String
    package let title: String
    package let startTime: Date
    package let endTime: Date?
    package let durationSeconds: Double?
    package let language: String
    package let seriesId: String?
    package let source: String
    package let status: String
    package let description: String?
    /// Why the status is `needsAttention` or `error` (app's MeetingStatusReason codes); nil when unknown.
    package let statusReason: String?
    package let createdAt: Date
}
