import Foundation

/// MCP tool: mark_excluded — marks a time interval of a track as "not for the
/// transcript". A write, so it travels to the running app over the command
/// socket: the app owns reprojection and embedding recalculation.
package enum MarkExcludedTool {
    package static let definition: AnyCodable = .object([
        "name": .string("mark_excluded"),
        "description": .string(
            "Mark a time interval of a meeting as 'not for the transcript': its segments are hidden from "
            + "the transcript, search, export and speaker-embedding training. Reversible — audio and text "
            + "are kept; use unmark to bring speech back. Acts on one track (default mic)."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_id": .object([
                    "type": .string("string"),
                    "description": .string("Meeting ID"),
                ]),
                "from": .object([
                    "type": .string("number"),
                    "description": .string("Interval start in seconds"),
                ]),
                "to": .object([
                    "type": .string("number"),
                    "description": .string("Interval end in seconds"),
                ]),
                "track": .object([
                    "type": .string("string"),
                    "description": .string("Track the mark acts on: mic (default), system, merged or import"),
                ]),
            ]),
            "required": .array([.string("meeting_id"), .string("from"), .string("to")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable]) throws -> String {
        guard let meetingId = params["meeting_id"]?.value as? String, !meetingId.isEmpty else {
            return "Error: meeting_id is required"
        }
        guard let from = params["from"]?.asDouble, let to = params["to"]?.asDouble, to > from else {
            return "Error: from/to are required, to must be greater than from"
        }
        var commandParams = [
            "meeting_id": meetingId,
            "from": String(from),
            "to": String(to),
        ]
        if let track = params["track"]?.value as? String, !track.isEmpty {
            commandParams["track"] = track
        }
        do {
            let response = try AppCommandDispatch.run(
                AppCommandRequest(command: AppCommandName.markExcluded, params: commandParams)
            )
            return AppCommandDispatch.describe(response)
        } catch {
            return "Error: \(error)"
        }
    }
}

/// MCP tool: unmark — either removes one mark by id, or lays an `included`
/// interval over a range so speech inside excluded intervals becomes visible
/// again (the explicit override of design D2).
package enum UnmarkTool {
    package static let definition: AnyCodable = .object([
        "name": .string("unmark"),
        "description": .string(
            "Undo exclusion. Pass mark_id (from list_marks) to delete that mark entirely, or pass from/to "
            + "to bring speech in that range back into the transcript (overrides earlier excluded intervals)."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_id": .object([
                    "type": .string("string"),
                    "description": .string("Meeting ID"),
                ]),
                "mark_id": .object([
                    "type": .string("integer"),
                    "description": .string("Id of the mark to delete (see list_marks)"),
                ]),
                "from": .object([
                    "type": .string("number"),
                    "description": .string("Range start in seconds (used when mark_id is omitted)"),
                ]),
                "to": .object([
                    "type": .string("number"),
                    "description": .string("Range end in seconds (used when mark_id is omitted)"),
                ]),
                "track": .object([
                    "type": .string("string"),
                    "description": .string("Track for the from/to form: mic (default), system, merged or import"),
                ]),
            ]),
            "required": .array([.string("meeting_id")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable]) throws -> String {
        guard let meetingId = params["meeting_id"]?.value as? String, !meetingId.isEmpty else {
            return "Error: meeting_id is required"
        }

        var commandParams = ["meeting_id": meetingId]
        let markId = (params["mark_id"]?.value as? Int).map(Int64.init)
            ?? (params["mark_id"]?.value as? Double).flatMap { Int64(exactly: $0) }
        if let markId {
            commandParams["mark_id"] = String(markId)
        } else {
            guard let from = params["from"]?.asDouble, let to = params["to"]?.asDouble, to > from else {
                return "Error: pass either mark_id, or from/to with to greater than from"
            }
            commandParams["from"] = String(from)
            commandParams["to"] = String(to)
            if let track = params["track"]?.value as? String, !track.isEmpty {
                commandParams["track"] = track
            }
        }

        do {
            let response = try AppCommandDispatch.run(
                AppCommandRequest(command: AppCommandName.unmark, params: commandParams)
            )
            return AppCommandDispatch.describe(response)
        } catch {
            return "Error: \(error)"
        }
    }
}

/// MCP tool: list_marks — read-only listing of a meeting's exclusion marks.
package enum ListMarksTool {
    package static let definition: AnyCodable = .object([
        "name": .string("list_marks"),
        "description": .string(
            "List the exclusion marks of a meeting: id, time range, track, kind (excluded/included) and origin."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_id": .object([
                    "type": .string("string"),
                    "description": .string("Meeting ID"),
                ]),
            ]),
            "required": .array([.string("meeting_id")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable], db: DatabaseReader) throws -> String {
        guard let meetingId = params["meeting_id"]?.value as? String, !meetingId.isEmpty else {
            return "Error: meeting_id is required"
        }
        let marks = try db.listMarks(meetingId: meetingId)
        guard !marks.isEmpty else {
            return "No marks for meeting \(meetingId)."
        }
        let lines = marks.map { mark -> String in
            let id = mark.id.map(String.init) ?? "?"
            let end = mark.endTime.map { formatMarkTime($0) } ?? "open"
            let name = (try? db.speakerName(forId: mark.speakerId)) ?? nil
            let who = mark.speakerId.map { " speaker_id=\($0) (\(name ?? "?"))" } ?? ""
            return "#\(id) [\(formatMarkTime(mark.startTime)) → \(end)] track=\(mark.track) \(mark.kind) (\(mark.source))\(who)"
        }
        return lines.joined(separator: "\n")
    }

    /// `hh:mm:ss.t` — marks can be shorter than a second (0.16–0.48 s printed
    /// as `00:00:00 → 00:00:00` looked like an empty mark); `formatTimestamp`
    /// stays whole-second for meeting durations.
    package static func formatMarkTime(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded())
        let h = tenths / 36_000
        let m = tenths % 36_000 / 600
        let s = tenths % 600
        return String(format: "%02d:%02d:%02d.%d", h, m, s / 10, s % 10)
    }
}
