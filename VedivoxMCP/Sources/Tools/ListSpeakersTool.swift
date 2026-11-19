import Foundation

/// MCP tool: list_speakers — Lists speakers, optionally filtered by meeting.
package enum ListSpeakersTool {
    package static let definition: AnyCodable = .object([
        "name": .string("list_speakers"),
        "description": .string(
            "List speakers. If meeting_id provided, shows speakers in that meeting. " +
            "Otherwise shows all speakers with meeting counts."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "meeting_id": .object([
                    "type": .string("string"),
                    "description": .string("Optional meeting ID to filter speakers"),
                ]),
            ]),
        ]),
    ])

    package static func run(params: [String: AnyCodable], db: DatabaseReader) throws -> String {
        let meetingId = params["meeting_id"]?.value as? String

        let results = try db.listSpeakers(meetingId: meetingId)

        if results.isEmpty {
            return "No speakers found."
        }

        var lines: [String] = []
        for (index, result) in results.enumerated() {
            let s = result.speaker
            let star = s.isMe ? " (\u{2605})" : ""
            let meetingLabel = result.meetingCount == 1 ? "meeting" : "meetings"

            var extras: [String] = []
            if let nickname = s.nickname, !nickname.isEmpty { extras.append("nickname: \(nickname)") }
            if let nameRu = s.nameRu, !nameRu.isEmpty { extras.append("ru: \(nameRu)") }
            if s.nameEn != s.displayName { extras.append("en: \(s.nameEn)") }
            let extraStr = extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))"

            lines.append(
                "\(index + 1). [\(s.id)] \(s.displayName)\(star)\(extraStr) — \(result.meetingCount) \(meetingLabel)"
            )
        }

        return lines.joined(separator: "\n")
    }
}
