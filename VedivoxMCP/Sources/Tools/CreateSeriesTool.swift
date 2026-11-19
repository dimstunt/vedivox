import Foundation

/// MCP tool: create_series — Creates a new meeting series.
package enum CreateSeriesTool {
    package static let definition: AnyCodable = .object([
        "name": .string("create_series"),
        "description": .string(
            "Create a new meeting series. Returns the generated series_id which can be used " +
            "with update_meeting to attach meetings to the series."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Series name (e.g. '1:1 with Alice', 'Weekly Standup')"),
                ]),
                "calendar_series_id": .object([
                    "type": .string("string"),
                    "description": .string("Optional calendar recurring event ID to link to"),
                ]),
            ]),
            "required": .array([.string("name")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable]) throws -> String {
        guard let name = params["name"]?.value as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: name is required"
        }

        var commandParams = ["name": name]
        if let calendarSeriesId = params["calendar_series_id"]?.value as? String, !calendarSeriesId.isEmpty {
            commandParams["calendar_series_id"] = calendarSeriesId
        }

        do {
            let response = try AppCommandDispatch.run(
                AppCommandRequest(command: AppCommandName.createSeries, params: commandParams)
            )
            return AppCommandDispatch.describe(response)
        } catch {
            return "Error: \(error)"
        }
    }
}
