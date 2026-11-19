import Foundation

/// MCP tool: update_speaker — Updates speaker profile fields.
package enum UpdateSpeakerTool {
    package static let definition: AnyCodable = .object([
        "name": .string("update_speaker"),
        "description": .string(
            "Update speaker profile. Supports changing name, nickname, nameRu, nameEn, and isMe flag. " +
            "Only provided fields are updated; omitted fields remain unchanged. " +
            "Setting isMe to true will unmark the previous 'me' speaker."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "speaker_id": .object([
                    "type": .string("string"),
                    "description": .string("Speaker ID"),
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Speaker display name"),
                ]),
                "nickname": .object([
                    "type": .string("string"),
                    "description": .string("Speaker nickname/handle (set to empty string to clear)"),
                ]),
                "name_ru": .object([
                    "type": .string("string"),
                    "description": .string("Speaker name in Russian (set to empty string to clear)"),
                ]),
                "name_en": .object([
                    "type": .string("string"),
                    "description": .string("Speaker name in English (set to empty string to clear)"),
                ]),
                "is_me": .object([
                    "type": .string("boolean"),
                    "description": .string("Mark this speaker as 'me' (the app user)"),
                ]),
            ]),
            "required": .array([.string("speaker_id")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable]) throws -> String {
        guard let speakerId = params["speaker_id"]?.value as? String, !speakerId.isEmpty else {
            return "Error: speaker_id is required"
        }

        // Presence is the signal, not the value: an absent field is left alone,
        // an empty one is cleared. Collapsing the two would make it impossible
        // to erase a nickname.
        var fields: [String: String] = [:]
        // Only a string counts: JSON null (or a number) is not "clear this field".
        for key in ["name", "nickname", "name_ru", "name_en"] {
            if let value = params[key]?.value as? String { fields[key] = value }
        }
        if let isMe = params["is_me"]?.value as? Bool {
            fields["is_me"] = isMe ? "1" : "0"
        }

        guard !fields.isEmpty else {
            return "Error: at least one field must be provided"
        }

        var commandParams = fields
        commandParams["speaker_id"] = speakerId

        do {
            let response = try AppCommandDispatch.run(
                AppCommandRequest(command: AppCommandName.updateSpeaker, params: commandParams)
            )
            return AppCommandDispatch.describe(response)
        } catch {
            return "Error: \(error)"
        }
    }
}
