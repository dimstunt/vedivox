import Foundation

/// MCP tool: update_meeting — Updates meeting metadata (title, description, series).
package enum UpdateMeetingTool {
    package static let definition: AnyCodable = .object([
        "name": .string("update_meeting"),
        "description": .string(
            "Update meeting metadata. Supports changing title, description, and series. " +
            "Only provided fields are updated; omitted fields remain unchanged."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_id": .object([
                    "type": .string("string"),
                    "description": .string("Meeting ID"),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string("New meeting title"),
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("New meeting description (set to empty string to clear)"),
                ]),
                "series_id": .object([
                    "type": .string("string"),
                    "description": .string("New series ID (set to empty string to unlink from series)"),
                ]),
            ]),
            "required": .array([.string("meeting_id")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable]) throws -> String {
        guard let meetingId = params["meeting_id"]?.value as? String, !meetingId.isEmpty else {
            return "Error: meeting_id is required"
        }

        // Presence means "set", value may be empty to clear.
        var fields: [String: String] = [:]
        // Only a string counts: JSON null (or a number) is not "clear this field".
        for key in ["title", "description", "series_id"] {
            if let value = params[key]?.value as? String { fields[key] = value }
        }

        guard !fields.isEmpty else {
            return "Error: at least one field (title, description, series_id) must be provided"
        }

        var commandParams = fields
        commandParams["meeting_id"] = meetingId

        do {
            let response = try AppCommandDispatch.run(
                AppCommandRequest(command: AppCommandName.updateMeeting, params: commandParams)
            )
            return AppCommandDispatch.describe(response)
        } catch {
            return "Error: \(error)"
        }
    }
}
