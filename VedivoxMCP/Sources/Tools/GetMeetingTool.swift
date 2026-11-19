import Foundation

/// MCP tool: get_meeting — Returns meeting metadata without the transcript.
package enum GetMeetingTool {
    package static let definition: AnyCodable = .object([
        "name": .string("get_meeting"),
        "description": .string(
            "Get meeting metadata (title, description, date, duration, speakers, series) without the full transcript."
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
        guard let meetingId = params["meeting_id"]?.value as? String else {
            return "Error: meeting_id is required"
        }

        let meeting = try db.getMeeting(meetingId: meetingId)

        let dateFormatter = DateFormatter()
        // POSIX pins the Gregorian calendar: the system one can be Buddhist (year 2569).
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let date = dateFormatter.string(from: meeting.startTime)
        let duration = formatDuration(meeting.durationSeconds)
        let speakers = try db.speakerNames(forMeeting: meeting.id)
        let seriesName = try db.seriesName(forId: meeting.seriesId)

        var lines: [String] = [
            "ID: \(meeting.id)",
            "Title: \(meeting.title)",
            "Date: \(date)",
            "Duration: \(duration)",
            "Status: \(meeting.status)",
            "URL: vedivox://meeting/\(meeting.id)",
        ]

        if let description = meeting.description, !description.isEmpty {
            lines.append("Description: \(description)")
        }

        if let seriesName, let seriesId = meeting.seriesId, !seriesId.isEmpty {
            lines.append("Series: \(seriesName) (\(seriesId))")
        }

        if !speakers.isEmpty {
            lines.append("Speakers: \(speakers.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }
}
