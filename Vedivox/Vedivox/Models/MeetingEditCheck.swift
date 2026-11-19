import Foundation

/// The limits the window's Split and Trim controls enforce before a button
/// can be pressed (`SplitCutPoint`, `SplitTrimSheet.canApply`); the
/// repository checks none of them. The command socket has no controls, so
/// it asks these instead (cli-meeting-edit, design § 3). Each returns why
/// the edit is refused, nil when it may go ahead. `segments` are
/// (start, end) seconds on the meeting's current timeline.
enum MeetingEditCheck {
    static func split(at time: Double, duration: Double, segments: [(start: Double, end: Double)]) -> String? {
        guard duration > 1 else { return "the meeting is too short to split" }
        guard time >= 1, time <= duration - 1 else {
            return "the cut must be between 1 and \(Int(duration - 1)) s"
        }
        // The repository moves lines that start at or after the cut.
        guard segments.contains(where: { $0.start < time }) else { return "the first part would have no lines" }
        guard segments.contains(where: { $0.start >= time }) else { return "the second part would have no lines" }
        return nil
    }

    static func trim(from: Double, to: Double, duration: Double, segments: [(start: Double, end: Double)]) -> String? {
        guard duration > 1 else { return "the meeting is too short to trim" }
        guard from >= 0, to <= duration, to - from >= 1 else {
            return "keep at least 1 s within 0–\(Int(duration)) s"
        }
        guard from > 0 || to < duration else { return "nothing would be cut off" }
        // The repository keeps lines that overlap the kept range.
        guard segments.contains(where: { $0.end > from && $0.start < to }) else { return "no lines would be left" }
        return nil
    }
}
