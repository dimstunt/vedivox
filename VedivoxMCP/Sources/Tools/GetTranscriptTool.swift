import Foundation

/// MCP tool: get_transcript — Returns the full transcript of a meeting.
package enum GetTranscriptTool {
    package static let definition: AnyCodable = .object([
        "name": .string("get_transcript"),
        "description": .string(
            "Get the transcript of a meeting with speaker labels and timestamps. Use from/to to get a specific time range (in seconds)."
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
                    "description": .string("Start time in seconds (inclusive). Omit to start from beginning."),
                ]),
                "to": .object([
                    "type": .string("number"),
                    "description": .string("End time in seconds (inclusive). Omit to go until the end."),
                ]),
                "include_excluded": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Also return segments marked 'not for the transcript' (shown with an [excluded] tag). Default false."
                    ),
                ]),
            ]),
            "required": .array([.string("meeting_id")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable], db: DatabaseReader) throws -> String {
        guard let meetingId = params["meeting_id"]?.value as? String else {
            return "Error: meeting_id is required"
        }

        let fromTime = params["from"]?.asDouble
        let toTime = params["to"]?.asDouble
        let includeExcluded = params["include_excluded"]?.value as? Bool ?? false

        let (meeting, segments) = try db.getTranscript(
            meetingId: meetingId, from: fromTime, to: toTime, includeExcluded: includeExcluded
        )

        let dateFormatter = DateFormatter()
        // POSIX pins the Gregorian calendar: the system one can be Buddhist (year 2569).
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let date = dateFormatter.string(from: meeting.startTime)
        let duration = formatDuration(meeting.durationSeconds)

        var lines: [String] = [
            "Meeting: \(meeting.title)",
            "Date: \(date)",
            "Duration: \(duration)",
            "URL: vedivox://meeting/\(meetingId)",
            "",
        ]

        // Block assembly is shared with the CLI (TranscriptAssembly); only the
        // line format below is MCP's own.
        let blocks = try assembleTranscriptBlocks(
            segments: segments,
            resolveSpeaker: makeSpeakerResolver(db: db)
        )
        for block in blocks {
            let start = formatTimestamp(block.startTime)
            let end = formatTimestamp(block.endTime)
            lines.append("[\(start) → \(end)] \(block.speaker): \(block.text)")
        }

        return lines.joined(separator: "\n")
    }
}
