import Foundation

/// The meetings the pipeline is working on, for the sidebar's
/// «Processing N meetings…» line.
enum ProcessingMeetings {
    /// `recordingId`: the meeting being recorded right now, if any. A stopped
    /// recording keeps `.recording` in memory while it is processed (the
    /// pipeline writes `.transcribing` to the database without reloading the
    /// list), so `.recording` counts unless it is that meeting.
    static func of(_ meetings: [Meeting], recordingId: String?) -> [Meeting] {
        meetings.filter { $0.status.isInProgress && $0.id != recordingId }
    }

    static func label(_ count: Int) -> String {
        count == 1 ? "Processing 1 meeting…" : "Processing \(count) meetings…"
    }
}
