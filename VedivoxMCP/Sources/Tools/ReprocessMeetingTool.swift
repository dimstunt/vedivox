import Foundation

/// MCP tool: reprocess_meeting — Re-transcribes and re-diarizes a meeting.
///
/// Sends the command to the instance that owns the data directory and waits for
/// it to finish, then reports what happened. The previous version handed a
/// `vedivox://` URL to `/usr/bin/open` and treated its exit code as success — a
/// code that means "the system accepted the link" and was zero on 2026-08-14
/// when nothing ran at all.
/// Diarization uses speaker enrollment: known speakers are automatically recognized by voice.
package enum ReprocessMeetingTool {
    package static let definition: AnyCodable = .object([
        "name": .string("reprocess_meeting"),
        "description": .string(
            "Re-transcribe and re-diarize a meeting. Waits for Vedivox to finish and "
            + "reports the actual outcome, not just that the request was sent. "
            + "Known speakers are automatically recognized by voice enrollment."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_id": .object([
                    "type": .string("string"),
                    "description": .string("Meeting ID to reprocess"),
                ]),
                "suppress_echo": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Apply echo suppression to mic audio (for calls played through speakers). "
                        + "Omit to autodetect speaker bleed via envelope correlation."
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

        // Fail here rather than at the app: a bad id is the caller's mistake,
        // and answering it without a round trip keeps the error specific.
        _ = try db.getMeeting(meetingId: meetingId)

        var commandParams = ["meeting_id": meetingId]
        // Absent means autodetect — not the same as false, so it is
        // only sent when the caller actually chose.
        if let suppressEcho = params["suppress_echo"]?.value as? Bool {
            commandParams["suppress_echo"] = suppressEcho ? "1" : "0"
        }

        do {
            let response = try AppCommandDispatch.run(
                AppCommandRequest(command: AppCommandName.reprocessMeeting, params: commandParams)
            )
            return AppCommandDispatch.describe(response)
        } catch {
            return "Error: \(error)"
        }
    }
}
