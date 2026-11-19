import Foundation

/// MCP tool: update_segment — Updates the speaker assignment on a transcript segment.
package enum UpdateSegmentTool {
    package static let definition: AnyCodable = .object([
        "name": .string("update_segment"),
        "description": .string(
            "Change the speaker assigned to a transcript segment. "
            + "Use this to fix diarization errors on individual segments."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "segment_id": .object([
                    "type": .string("integer"),
                    "description": .string("Transcript segment ID"),
                ]),
                "speaker_id": .object([
                    "type": .string("string"),
                    "description": .string("Speaker ID to assign to the segment"),
                ]),
            ]),
            "required": .array([.string("segment_id"), .string("speaker_id")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable]) throws -> String {
        guard let segmentId = (params["segment_id"]?.value as? Int).map(Int64.init)
            ?? (params["segment_id"]?.value as? Double).flatMap({ Int64(exactly: $0) })
        else {
            return "Error: segment_id is required (integer)"
        }

        guard let speakerId = params["speaker_id"]?.value as? String, !speakerId.isEmpty else {
            return "Error: speaker_id is required"
        }

        do {
            let response = try AppCommandDispatch.run(
                AppCommandRequest(
                    command: AppCommandName.updateSegment,
                    params: ["segment_id": String(segmentId), "speaker_id": speakerId]
                )
            )
            return AppCommandDispatch.describe(response)
        } catch {
            return "Error: \(error)"
        }
    }
}
