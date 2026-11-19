import Foundation

/// MCP tools: split_meeting, trim_meeting, merge_meetings, undo_meeting_edit —
/// the app's Split, Trim, Merge Meetings and their Undo, through the same
/// chains as `vedivox meeting …` (`MeetingEdits`, cli-meeting-edit). Like
/// reprocess_meeting they act at once and report the app's outcome.
package enum MeetingEditTools {
    private static func meetingIdProperty(_ text: String) -> AnyCodable {
        .object(["type": .string("string"), "description": .string(text)])
    }

    package static let splitDefinition: AnyCodable = .object([
        "name": .string("split_meeting"),
        "description": .string(
            "Cut a meeting into parts at the given seconds from the start of its recording (a line's start "
                + "is the first time of its \"[HH:MM:SS → HH:MM:SS]\" in get_transcript, in seconds). "
                + "The meeting stays the first part; the others are new meetings titled "
                + "\"… (2)\". Several points cut from the last back. Each part must keep a line, cuts at "
                + "least 1 s apart. Only the last cut can be undone (undo_meeting_edit kind=split)."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_id": meetingIdProperty("Meeting ID to split"),
                "at": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("number")]),
                    "description": .string("Cut points in seconds"),
                ]),
            ]),
            "required": .array([.string("meeting_id"), .string("at")]),
        ]),
    ])

    package static let trimDefinition: AnyCodable = .object([
        "name": .string("trim_meeting"),
        "description": .string(
            "Keep only the stretch from..to (seconds) of a meeting; audio and lines outside it are removed. "
                + "Undo with undo_meeting_edit kind=trim (it reprocesses the meeting)."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_id": meetingIdProperty("Meeting ID to trim"),
                "from": .object(["type": .string("number"), "description": .string("Keep from (default 0)")]),
                "to": .object(["type": .string("number"), "description": .string("Keep up to (default: the end)")]),
            ]),
            "required": .array([.string("meeting_id")]),
        ]),
    ])

    package static let mergeDefinition: AnyCodable = .object([
        "name": .string("merge_meetings"),
        "description": .string(
            "Join two or more meetings into the earliest one, in order of start; the others are deleted "
                + "after their lines and audio move over. Only the last join can be undone "
                + "(undo_meeting_edit kind=merge)."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Meeting IDs, two or more"),
                ]),
            ]),
            "required": .array([.string("meeting_ids")]),
        ]),
    ])

    package static let undoDefinition: AnyCodable = .object([
        "name": .string("undo_meeting_edit"),
        "description": .string(
            "Undo the last split, trim or merge of a meeting. A split is undone from either part. Undoing a "
                + "trim reprocesses the meeting (text and speaker edits are lost) and waits for it."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_id": meetingIdProperty("Meeting ID"),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array(MeetingEdits.undoKinds.map { .string($0) }),
                ]),
            ]),
            "required": .array([.string("meeting_id"), .string("kind")]),
        ]),
    ])

    /// JSON numbers arrive as Int or Double.
    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    private static func send(_ request: AppCommandRequest) throws -> AppCommandResponse {
        try AppCommandDispatch.run(request)
    }

    private static func stopped(_ stop: MeetingEdits.ChainStopped) -> String {
        let refusal = AppCommandDispatch.describe(stop.response)
        return stop.done.isEmpty ? refusal : "Already done: \(stop.done.joined(separator: "; ")). Then: \(refusal)"
    }

    package static func split(params: [String: AnyCodable], db: DatabaseReader) throws -> String {
        guard let meetingId = params["meeting_id"]?.value as? String else { return "Error: meeting_id is required" }
        let times = (params["at"]?.value as? [AnyCodable] ?? []).compactMap { number($0.value) }
        let (meeting, segments) = try db.getTranscript(meetingId: meetingId, includeExcluded: true)
        if let why = MeetingEdits.splitRefusal(
            at: times, duration: meeting.durationSeconds ?? 0, lineStarts: segments.map(\.startTime)
        ) {
            return "Error: cannot split: \(why)"
        }
        do {
            let ids = try MeetingEdits.split(meetingId: meetingId, at: times, send: send)
            return "Split into \(ids.count) meetings: \(ids.joined(separator: ", "))"
        } catch let stop as MeetingEdits.ChainStopped {
            return stopped(stop)
        } catch {
            return "Error: \(error)"
        }
    }

    package static func trim(params: [String: AnyCodable], db: DatabaseReader) throws -> String {
        guard let meetingId = params["meeting_id"]?.value as? String else { return "Error: meeting_id is required" }
        let meeting = try db.getMeeting(meetingId: meetingId)
        let from = number(params["from"]?.value) ?? 0
        let to = number(params["to"]?.value) ?? meeting.durationSeconds ?? 0
        do {
            return AppCommandDispatch.describe(try MeetingEdits.trim(meetingId: meetingId, from: from, to: to, send: send))
        } catch {
            return "Error: \(error)"
        }
    }

    package static func merge(params: [String: AnyCodable], db: DatabaseReader) throws -> String {
        var seen = Set<String>()
        let ids = (params["meeting_ids"]?.value as? [AnyCodable] ?? []).compactMap { $0.value as? String }
            .filter { seen.insert($0).inserted }
        guard ids.count >= 2 else { return "Error: meeting_ids needs two or more different meetings" }
        let ordered = try ids.map { try db.getMeeting(meetingId: $0) }.sorted { $0.startTime < $1.startTime }.map(\.id)
        do {
            let result = try MeetingEdits.merge(meetingIds: ordered, send: send)
            return "Merged \(result.merged.joined(separator: ", ")) into \(result.meeting)"
        } catch let stop as MeetingEdits.ChainStopped {
            return stopped(stop)
        } catch {
            return "Error: \(error)"
        }
    }

    package static func undo(params: [String: AnyCodable], db: DatabaseReader) throws -> String {
        guard let meetingId = params["meeting_id"]?.value as? String else { return "Error: meeting_id is required" }
        guard let kind = params["kind"]?.value as? String, MeetingEdits.undoKinds.contains(kind) else {
            return "Error: kind must be split, trim or merge"
        }
        _ = try db.getMeeting(meetingId: meetingId)
        do {
            return AppCommandDispatch.describe(try MeetingEdits.undo(kind, meetingId: meetingId, send: send))
        } catch {
            return "Error: \(error)"
        }
    }
}
