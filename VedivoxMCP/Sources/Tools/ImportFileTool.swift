import Foundation

/// MCP tool: import_file — Imports an audio/video file into Vedivox for transcription and diarization.
/// Speakers are automatically detected and recognized via voice enrollment.
package enum ImportFileTool {
    package static let supportedExtensions: Set<String> = [
        "mov", "mp4", "mp3", "wav", "aiff", "m4a", "webm", "ogg",
    ]

    package static let definition: AnyCodable = .object([
        "name": .string("import_file"),
        "description": .string(
            "Import an audio or video file into Vedivox for transcription and diarization. "
            + "Supported formats: mov, mp4, mp3, wav, aiff, m4a, webm, ogg. "
            + "Answers once Vedivox has copied the file and created the meeting; transcription then runs "
            + "in the background — the status is in list_meetings (transcribing, diarizing, done, error). "
            + "Known speakers are automatically recognized by voice enrollment."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to the audio/video file"),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string("Meeting title. Defaults to filename."),
                ]),
                "date": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Meeting date, YYYY-MM-DD or ISO8601 (when the call happened, "
                        + "not when it is imported). Defaults to the file's creation date."
                    ),
                ]),
            ]),
            "required": .array([.string("file_path")]),
        ]),
    ])

    /// Mirrors the app-side ImportRequest.parseDate acceptance (VedivoxMCP is a
    /// standalone package, so the cascade is duplicated by design — keep the
    /// two in sync): ISO8601 with/without fractional seconds, timezone-less
    /// ISO datetime, or plain YYYY-MM-DD.
    package static func isValidDate(_ raw: String, timeZone: TimeZone = .current) -> Bool {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if isoFractional.date(from: raw) != nil { return true }
        if ISO8601DateFormatter().date(from: raw) != nil { return true }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        // A plain day is checked at noon: where the clocks go forward at 00:00
        // (Cairo, Santiago) that day has no midnight and "yyyy-MM-dd" fails.
        return formatter.date(from: raw) != nil || formatter.date(from: raw + "T12:00:00") != nil
    }

    package static func run(params: [String: AnyCodable]) throws -> String {
        guard let rawPath = params["file_path"]?.value as? String, !rawPath.isEmpty else {
            return "Error: file_path is required"
        }
        let filePath = (rawPath as NSString).expandingTildeInPath

        // Validate extension
        let ext = (filePath as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            return "Error: unsupported format .\(ext). Supported: \(supportedExtensions.sorted().joined(separator: ", "))"
        }

        // Validate file exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            return "Error: file not found at \(filePath)"
        }

        var commandParams = ["path": filePath]

        if let title = params["title"]?.value as? String, !title.isEmpty {
            commandParams["title"] = title
        }

        if let date = params["date"]?.value as? String, !date.isEmpty {
            // Rejected here as well as in the app: a caller's bad date deserves
            // an answer without a round trip, and a silent fall back to the
            // file's creation date files the meeting under the wrong day.
            guard isValidDate(date) else {
                return "Error: invalid date \"\(date)\" — use YYYY-MM-DD or ISO8601"
            }
            commandParams["date"] = date
        }

        do {
            let response = try AppCommandDispatch.run(
                AppCommandRequest(command: AppCommandName.importFile, params: commandParams)
            )
            return AppCommandDispatch.describe(response)
        } catch {
            return "Error: \(error)"
        }
    }
}
