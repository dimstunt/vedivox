import Foundation

/// MCP tool: list_meetings — Lists meetings with optional filters.
package enum ListMeetingsTool {
    package static let definition: AnyCodable = .object([
        "name": .string("list_meetings"),
        "description": .string(
            "List meetings with optional filters. Returns newest first by default. "
            + "By default only shows completed meetings. Use status filter to see "
            + "meetings in other states: recording, transcribing, diarizing, done, error."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "speaker": .object([
                    "type": .string("string"),
                    "description": .string("Filter by speaker name (partial match)"),
                ]),
                "speaker_ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Only meetings where ALL of these speakers took part (IDs from list_speakers)"
                    ),
                ]),
                "date_from": .object([
                    "type": .string("string"),
                    "description": .string("Start date (YYYY-MM-DD)"),
                ]),
                "date_to": .object([
                    "type": .string("string"),
                    "description": .string("End date (YYYY-MM-DD)"),
                ]),
                "series": .object([
                    "type": .string("string"),
                    "description": .string("Filter by meeting series name (partial match)"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max results (default 20)"),
                ]),
                "sort": .object([
                    "type": .string("string"),
                    "enum": .array([.string("newest"), .string("oldest")]),
                    "description": .string("Sort order (default newest)"),
                ]),
                "status": .object([
                    "description": .string(
                        "Filter by status. String or array of strings. "
                        + "Values: recording, transcribing, diarizing, done, error. "
                        + "Default: done."
                    ),
                ]),
            ]),
        ]),
    ])

    package static func run(params: [String: AnyCodable], db: DatabaseReader) throws -> String {
        let speaker = params["speaker"]?.value as? String
        let speakerIds = (params["speaker_ids"]?.value as? [AnyCodable])?
            .compactMap { $0.value as? String } ?? []
        let dateFrom = params["date_from"]?.value as? String
        let dateTo = params["date_to"]?.value as? String
        let series = params["series"]?.value as? String
        let limit = max(1, params["limit"]?.value as? Int ?? 20) // SQLite reads a negative LIMIT as "no limit"
        let sort = params["sort"]?.value as? String ?? "newest"

        // Parse status: string, array of strings, or default to ["done"]
        let statuses: [String]
        if let single = params["status"]?.value as? String {
            statuses = [single]
        } else if let array = params["status"]?.value as? [AnyCodable] {
            statuses = array.compactMap { $0.value as? String }
        } else {
            statuses = ["done"]
        }

        let meetings = try db.listMeetings(
            speaker: speaker,
            speakerIds: speakerIds,
            dateFrom: dateFrom,
            dateTo: dateTo,
            series: series,
            statuses: statuses,
            limit: limit,
            sort: sort
        )

        if meetings.isEmpty {
            return "No meetings found."
        }
        return try formatLines(meetings, db: db)
    }

    /// One numbered line per meeting: id, title, date, duration, link, series, speakers.
    package static func formatLines(_ meetings: [Meeting], db: DatabaseReader) throws -> String {
        let dateFormatter = DateFormatter()
        // POSIX pins the Gregorian calendar: the system one can be Buddhist (year 2569).
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        for (index, meeting) in meetings.enumerated() {
            let date = dateFormatter.string(from: meeting.startTime)
            let duration = formatDuration(meeting.durationSeconds)
            let speakers = try db.speakerNames(forMeeting: meeting.id)
            let speakerList = speakers.isEmpty ? "Unknown" : speakers.joined(separator: ", ")
            let seriesName = try db.seriesName(forId: meeting.seriesId)
            let deepLink = "vedivox://meeting/\(meeting.id)"
            let statusLabel = meeting.status != "done" ? " [\(meeting.status)]" : ""
            var line = "\(index + 1). [\(meeting.id)] \(meeting.title) (\(date), \(duration))\(statusLabel) \(deepLink)"
            if let seriesName {
                line += " [\(seriesName)]"
            }
            line += " — Speakers: \(speakerList)"
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Formatting Helpers

/// Formats a duration in seconds as a human-readable string (e.g. "32m 15s" or "1h 5m").
package func formatDuration(_ seconds: Double?) -> String {
    guard let seconds, seconds > 0 else { return "0s" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    } else if m > 0 {
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    } else {
        return "\(s)s"
    }
}

/// Formats a time in seconds as HH:MM:SS.
package func formatTimestamp(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
}
