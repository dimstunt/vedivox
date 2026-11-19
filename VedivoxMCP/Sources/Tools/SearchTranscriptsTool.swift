import Foundation

/// MCP tool: search_transcripts — Full-text search across all meeting transcripts.
package enum SearchTranscriptsTool {
    package static let definition: AnyCodable = .object([
        "name": .string("search_transcripts"),
        "description": .string(
            "Full-text search across all meeting transcripts. Returns lines: every word of the query "
                + "(matched as a prefix) must occur in one line; titles and descriptions are not searched. "
                + "With meetings=true returns meetings instead: a meeting matches when every word occurs "
                + "somewhere in it — any line, its title or its description — like the app's sidebar search."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max results (default 20)"),
                ]),
                "meetings": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Search whole meetings (lines, title, description) and list the meetings found, "
                            + "newest first. Default false: lines where all words occur together."
                    ),
                ]),
                "include_excluded": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Also search segments marked 'not for the transcript' (shown with an [excluded] tag). Default false."
                    ),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable], db: DatabaseReader) throws -> String {
        guard let query = params["query"]?.value as? String, !query.isEmpty else {
            return "Error: query is required"
        }

        let limit = max(1, params["limit"]?.value as? Int ?? 20) // SQLite reads a negative LIMIT as "no limit"
        let includeExcluded = params["include_excluded"]?.value as? Bool ?? false
        if params["meetings"]?.value as? Bool == true {
            let meetings = try db.searchMeetings(query: query, limit: limit, includeExcluded: includeExcluded)
            if meetings.isEmpty { return "No meetings found for \"\(query)\"." }
            return try ListMeetingsTool.formatLines(meetings, db: db)
        }
        let results = try db.searchTranscripts(query: query, limit: limit, includeExcluded: includeExcluded)

        if results.isEmpty {
            return "No results found for \"\(query)\"."
        }

        let dateFormatter = DateFormatter()
        // POSIX pins the Gregorian calendar: the system one can be Buddhist (year 2569).
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        for result in results {
            let meetingDate: String
            // Look up meeting date from the segment's meetingId
            if let meetingData = try? db.getTranscript(meetingId: result.segment.meetingId) {
                meetingDate = dateFormatter.string(from: meetingData.meeting.startTime)
            } else {
                meetingDate = "unknown"
            }

            let timestamp = formatTimestamp(result.segment.startTime)
            var speakerName: String
            if let speakerId = result.segment.speakerId {
                speakerName = (try? db.speakerName(forId: speakerId))
                    ?? result.segment.speakerLabel ?? "Unknown"
            } else {
                speakerName = result.segment.speakerLabel ?? "Unknown"
            }
            if result.segment.isExcluded {
                speakerName += " [excluded]"
            }

            lines.append(
                "[\(result.meetingTitle), \(meetingDate) \(timestamp)] \(speakerName): \(result.segment.text)"
            )
        }

        return lines.joined(separator: "\n")
    }
}
