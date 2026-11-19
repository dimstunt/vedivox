import Foundation

/// MCP tool: list_series — Lists all meeting series.
package enum ListSeriesTool {
    package static let definition: AnyCodable = .object([
        "name": .string("list_series"),
        "description": .string(
            "List all meeting series with their IDs, names, and meeting counts. " +
            "Use this to find a series_id for update_meeting, or to decide whether to create a new series."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]),
    ])

    package static func run(params _: [String: AnyCodable], db: DatabaseReader) throws -> String {
        let seriesList = try db.listSeries()

        guard !seriesList.isEmpty else {
            return "No meeting series found."
        }

        var lines: [String] = ["Found \(seriesList.count) series:"]
        for (series, count) in seriesList {
            var line = "- \(series.name) (id: \(series.id), meetings: \(count)"
            if let calendarId = series.calendarSeriesId, !calendarId.isEmpty {
                line += ", calendar: \(calendarId)"
            }
            line += ")"
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
