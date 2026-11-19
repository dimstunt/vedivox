import Foundation
import GRDB

/// Read-only model matching the `meeting_marks` table: time intervals of one
/// track marked "not for the transcript" (kind `excluded`) or explicitly
/// brought back (kind `included`). `endTime` is NULL while a recording-time
/// button interval is still open.
package struct MeetingMark: Identifiable, Decodable, FetchableRecord, Sendable {
    package let id: Int64?
    package let meetingId: String
    package let startTime: Double
    package let endTime: Double?
    package let track: String
    package let kind: String
    package let source: String
    /// The speaker a `speaker` verdict names (listen-queue); nil on other kinds.
    package let speakerId: String?
}
