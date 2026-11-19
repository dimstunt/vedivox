import Foundation

/// The meeting date an import carries (`import_file` over the command socket).
/// Lives outside VedivoxApp/FileImporter so it compiles into the headless
/// VedivoxCoreTests target (FileImporter.swift is excluded from it).
enum ImportRequest {
    /// Accepts the formats the MCP tools advertise (keep in sync with
    /// ImportFileTool.isValidDate — VedivoxMCP is a separate package): ISO8601
    /// with or without fractional seconds ("2026-07-10T15:00:00Z",
    /// "...00.123Z"), a timezone-less ISO datetime ("2026-07-10T15:00:00",
    /// local time), or a plain calendar day ("2026-07-10").
    static func parseDate(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let exact = isoFractional.date(from: raw) {
            return exact
        }
        if let exact = ISO8601DateFormatter().date(from: raw) {
            return exact
        }
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = timeZone
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        // A plain day is read as its noon, never its midnight. Where the
        // clocks go forward at 00:00 (Cairo, Beirut, Santiago, Havana) that
        // day has no midnight, and a date-only format answers nil for it.
        // Noon also keeps the meeting on the intended day in any rendering.
        return localFormatter.date(from: raw) ?? localFormatter.date(from: raw + "T12:00:00")
    }
}

extension ImportRequest {
    /// Copies the file into the new meeting's directory as `name` and lets
    /// `register` create the meeting for it. Returns the copy.
    ///
    /// If either step fails the directory goes too: with no meeting row
    /// pointing at it, it was disk space nobody could find — half a video,
    /// when it was the disk that filled up.
    static func stage(
        _ url: URL, as name: String, meetingId: String, audioRoot: URL? = nil,
        register: (URL) async throws -> Void
    ) async throws -> URL {
        let audioDir = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)
        let destURL = audioDir.appendingPathComponent(name)
        // The file behind a symlink, not the link: copyItem copies a link as
        // a link, and the meeting's "copy" then dies with the original — or
        // at once, when the link is relative.
        do {
            try FileManager.default.copyItem(at: url.resolvingSymlinksInPath(), to: destURL)
            try await register(destURL)
        } catch {
            try? FileManager.default.removeItem(at: audioDir)
            throw error
        }
        return destURL
    }
}
