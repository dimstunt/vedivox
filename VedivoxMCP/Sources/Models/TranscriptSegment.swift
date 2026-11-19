import Foundation
import GRDB

/// Read-only model matching the `transcript_segments` table in the Vedivox database.
package struct TranscriptSegment: Identifiable, Decodable, FetchableRecord, Sendable {
    package let id: Int64?
    package let meetingId: String
    package let speakerId: String?
    package let speakerLabel: String?
    package let source: String
    package let startTime: Double
    package let endTime: Double
    package let text: String
    package let confidence: Double?
    /// Derived cache of the exclusion marks (`meeting_marks`): hidden from
    /// every default read surface, returned only on explicit request.
    package let isExcluded: Bool
}
