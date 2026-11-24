import Foundation
import GRDB

/// Errors specific to the MCP server database layer.
package enum MCPError: Error, Sendable {
    case databaseNotFound(path: String)
    case meetingNotFound(id: String)
    case invalidArgument(name: String, reason: String)
}

/// What an MCP client reads after "Error: " — not the Swift case name.
extension MCPError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .databaseNotFound(let path): "Vedivox database not found at \(path) — open Vedivox once to create it"
        case .meetingNotFound(let id): "meeting \(id) not found"
        case .invalidArgument(let name, let reason): "invalid \(name): \(reason)"
        }
    }
}

/// Read-only access to the Vedivox SQLite database.
///
/// Read-only in fact, not only in name. Until this change the class performed
/// `UPDATE speakers` and `UPDATE transcript_segments` while its comment
/// promised otherwise, and the resulting foreign writes went around the app's
/// own state — which is why the interface had to be told about its data
/// changing by a distributed notification. Changes now travel to the app as
/// commands; this connection only reads.
package final class DatabaseReader: Sendable {
    package let dbQueue: DatabaseQueue

    /// How long a read waits for the database to become available.
    ///
    /// Set explicitly because the GRDB default is `.immediateError`: a read
    /// that happens to land while the app is writing would fail outright, and
    /// a monitoring loop cannot tell that apart from "nothing to report".
    package static let busyTimeout: TimeInterval = 5

    /// Opens the Vedivox database for reading.
    ///
    /// - Throws: `MCPError.databaseNotFound` if the database file does not exist.
    package init() throws {
        let dbPath = VedivoxDataDirectory.root
            .appendingPathComponent("Vedivox.sqlite")
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw MCPError.databaseNotFound(path: dbPath)
        }

        self.dbQueue = try DatabaseQueue(path: dbPath, configuration: Self.configuration)
    }

    /// How this process opens the database.
    ///
    /// Exposed so a test can open a database exactly the way production does,
    /// rather than assert against a configuration it built itself.
    package static var configuration: Configuration {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(busyTimeout)
        return config
    }

    /// Creates a DatabaseReader backed by the given queue (for testing).
    package init(queue: DatabaseQueue) {
        self.dbQueue = queue
    }

    // MARK: - Query Methods

    /// The first moment of a `YYYY-MM-DD` day in the caller's time zone.
    ///
    /// `startTime` is stored in UTC, the day a person names is local. Compared
    /// as text, an evening meeting west of Greenwich fell on the next day and
    /// `--from today --to today` did not find it.
    static func dayStart(_ raw: String, name: String, plusDays: Int = 0, in timeZone: TimeZone) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Read at noon: a day can lack a midnight (clocks forward at 00:00).
        guard let noon = formatter.date(from: raw + "T12:00:00"),
              let day = calendar.date(byAdding: .day, value: plusDays, to: noon) else {
            throw MCPError.invalidArgument(name: name, reason: "\"\(raw)\" is not a YYYY-MM-DD date")
        }
        return calendar.startOfDay(for: day)
    }

    /// Lists meetings with optional filters.
    ///
    /// - Parameters:
    ///   - speaker: Partial speaker name match (LIKE %name%).
    ///   - dateFrom: Start date filter (YYYY-MM-DD), inclusive.
    ///   - dateTo: End date filter (YYYY-MM-DD), inclusive.
    ///   - series: Partial series name match (LIKE %name%).
    ///   - statuses: Status values to include. Defaults to `["done"]`.
    ///   - limit: Maximum number of results.
    ///   - sort: Sort order — "newest" (default) or "oldest".
    /// - Returns: Array of meetings matching the filters.
    package func listMeetings(
        speaker: String?,
        speakerIds: [String] = [],
        dateFrom: String?,
        dateTo: String?,
        series: String?,
        statuses: [String] = ["done"],
        limit: Int,
        sort: String,
        timeZone: TimeZone = .current
    ) throws -> [Meeting] {
        try dbQueue.read { db in
            let placeholders = statuses.map { _ in "?" }.joined(separator: ", ")
            var clauses: [String] = ["m.status IN (\(placeholders))"]
            var arguments: [any DatabaseValueConvertible] = statuses.map { $0 as any DatabaseValueConvertible }

            var joins = ""

            if let speaker, !speaker.isEmpty {
                joins += """
                     JOIN meeting_speakers ms ON ms.meetingId = m.id \
                    JOIN speakers sp ON sp.id = ms.speakerId
                    """
                clauses.append("sp.nameEn LIKE ?")
                arguments.append("%\(speaker)%")
            }

            // Meetings where ALL of the given speakers took part.
            let wantedSpeakers = Set(speakerIds)
            if !wantedSpeakers.isEmpty {
                let ids = wantedSpeakers.map { _ in "?" }.joined(separator: ", ")
                clauses.append("""
                    m.id IN (
                        SELECT meetingId FROM meeting_speakers
                        WHERE speakerId IN (\(ids))
                        GROUP BY meetingId
                        HAVING COUNT(DISTINCT speakerId) = ?
                    )
                    """)
                arguments.append(contentsOf: wantedSpeakers.map { $0 as any DatabaseValueConvertible })
                arguments.append(wantedSpeakers.count)
            }

            if let series, !series.isEmpty {
                joins += " JOIN meeting_series ser ON ser.id = m.seriesId"
                clauses.append("ser.name LIKE ?")
                arguments.append("%\(series)%")
            }

            if let dateFrom, !dateFrom.isEmpty {
                clauses.append("m.startTime >= ?")
                arguments.append(try Self.dayStart(dateFrom, name: "date_from", in: timeZone))
            }

            if let dateTo, !dateTo.isEmpty {
                clauses.append("m.startTime < ?")
                arguments.append(try Self.dayStart(dateTo, name: "date_to", plusDays: 1, in: timeZone))
            }

            let whereClause = clauses.joined(separator: " AND ")
            let orderDir = sort == "oldest" ? "ASC" : "DESC"

            let sql = """
                SELECT DISTINCT m.*
                FROM meetings m
                \(joins)
                WHERE \(whereClause)
                ORDER BY m.startTime \(orderDir)
                LIMIT ?
                """
            arguments.append(limit)

            return try Meeting.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Fetches a meeting and its full transcript.
    ///
    /// - Parameter meetingId: The meeting ID.
    /// - Returns: A tuple of the meeting and its transcript segments.
    /// - Throws: `MCPError.meetingNotFound` if no meeting with the given ID exists.
    package func getTranscript(
        meetingId: String,
        from: Double? = nil,
        to: Double? = nil,
        includeExcluded: Bool = false
    ) throws -> (meeting: Meeting, segments: [TranscriptSegment]) {
        try dbQueue.read { db in
            guard let meeting = try Meeting.fetchOne(
                db,
                sql: "SELECT * FROM meetings WHERE id = ?",
                arguments: [meetingId]
            ) else {
                throw MCPError.meetingNotFound(id: meetingId)
            }

            var clauses = ["meetingId = ?"]
            var args: [any DatabaseValueConvertible] = [meetingId]

            // Excluded segments are hidden by default on every read surface;
            // include_excluded is the explicit opt-in (design D4).
            if !includeExcluded {
                clauses.append("isExcluded = 0")
            }

            if let from {
                clauses.append("endTime >= ?")
                args.append(from)
            }
            if let to {
                clauses.append("startTime <= ?")
                args.append(to)
            }

            let whereClause = clauses.joined(separator: " AND ")
            let segments = try TranscriptSegment.fetchAll(
                db,
                sql: """
                    SELECT * FROM transcript_segments
                    WHERE \(whereClause)
                    ORDER BY startTime
                    """,
                arguments: StatementArguments(args)
            )

            return (meeting, segments)
        }
    }

    /// Lists speakers, optionally filtered by meeting.
    ///
    /// - Parameter meetingId: If provided, lists only speakers in that meeting.
    /// - Returns: Array of tuples containing the speaker and their meeting count.
    package func listSpeakers(meetingId: String?) throws -> [(speaker: Speaker, meetingCount: Int)] {
        try dbQueue.read { db in
            if let meetingId, !meetingId.isEmpty {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT s.*, COUNT(DISTINCT ms2.meetingId) as meetingCount
                        FROM speakers s
                        JOIN meeting_speakers ms ON ms.speakerId = s.id
                        LEFT JOIN meeting_speakers ms2 ON ms2.speakerId = s.id
                        WHERE ms.meetingId = ?
                        GROUP BY s.id
                        ORDER BY s.nameEn
                        """,
                    arguments: [meetingId]
                )
                return try rows.map { row in
                    let speaker = try Speaker(row: row)
                    let count: Int = row["meetingCount"]
                    return (speaker, count)
                }
            } else {
                // Global listing hides unconfirmed auto-labels: they are
                // per-meeting slot rows, not persons (speaker-row-per-mint).
                // The per-meeting branch above keeps them so they can still be
                // named or merged. Filtered in Swift with the strict
                // ^speaker_\\d+$ shape — a GLOB would also sweep up a human
                // name like "speaker_1a".
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT s.*, COUNT(DISTINCT ms.meetingId) as meetingCount
                        FROM speakers s
                        LEFT JOIN meeting_speakers ms ON ms.speakerId = s.id
                        GROUP BY s.id
                        ORDER BY meetingCount DESC, s.nameEn
                        """
                )
                return try rows.map { row in
                    let speaker = try Speaker(row: row)
                    let count: Int = row["meetingCount"]
                    return (speaker, count)
                }.filter { entry in
                    !(entry.speaker.isConfirmed == false
                        && entry.speaker.nameEn.range(
                            of: "^speaker_[0-9]+$", options: .regularExpression
                        ) != nil)
                }
            }
        }
    }

    /// Full-text search across all transcripts using FTS5.
    ///
    /// - Parameters:
    ///   - query: The search query string.
    ///   - limit: Maximum number of results.
    /// - Returns: Array of tuples containing the segment and the meeting title.
    package func searchTranscripts(
        query: String,
        limit: Int,
        includeExcluded: Bool = false
    ) throws -> [(segment: TranscriptSegment, meetingTitle: String)] {
        try dbQueue.read { db in
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else {
                return []
            }

            // FTS stays in sync with ALL segments, so the exclusion filter
            // must live on the join, not in the index (design D4).
            let exclusionClause = includeExcluded ? "" : "AND ts.isExcluded = 0"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT ts.*, m.title as meetingTitle
                    FROM transcript_segments ts
                    JOIN transcript_fts ON transcript_fts.rowid = ts.id
                    JOIN meetings m ON m.id = ts.meetingId
                    WHERE transcript_fts MATCH ? \(exclusionClause)
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [pattern, limit]
            )

            return try rows.map { row in
                let segment = try TranscriptSegment(row: row)
                let title: String = row["meetingTitle"]
                return (segment, title)
            }
        }
    }

    /// Meetings in which every word of `query` occurs somewhere — as a prefix in
    /// any line, or in the title or description; the words may sit in different
    /// lines. The same rule as the app's sidebar (`MeetingRepository.meetingIds(matching:)`),
    /// newest first.
    package func searchMeetings(query: String, limit: Int, includeExcluded: Bool = false) throws -> [Meeting] {
        let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return [] }
        return try dbQueue.read { db in
            let exclusionClause = includeExcluded ? "" : "AND ts.isExcluded = 0"
            let meetings = try Meeting.fetchAll(db, sql: "SELECT * FROM meetings ORDER BY startTime DESC")
            var found: Set<String>?
            for word in words {
                var ids = Set<String>()
                if let pattern = FTS5Pattern(matchingAllPrefixesIn: word) {
                    ids = try Set(String.fetchAll(db, sql: """
                        SELECT DISTINCT ts.meetingId
                        FROM transcript_segments ts
                        JOIN transcript_fts ON transcript_fts.rowid = ts.id
                        WHERE transcript_fts MATCH ? \(exclusionClause)
                        """, arguments: [pattern]))
                }
                for meeting in meetings
                where meeting.title.localizedStandardContains(word)
                    || meeting.description?.localizedStandardContains(word) == true {
                    ids.insert(meeting.id)
                }
                found = found?.intersection(ids) ?? ids
                if found?.isEmpty == true { break }
            }
            let hits = found ?? []
            return Array(meetings.filter { hits.contains($0.id) }.prefix(limit))
        }
    }

    /// Fetches speaker names for a given meeting.
    ///
    /// - Parameter meetingId: The meeting ID.
    /// - Returns: Array of speaker names.
    /// Who spoke in the meeting: a voice whose lines are all hidden is left out, as the default transcript leaves them out.
    package func speakerNames(forMeeting meetingId: String) throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.nameEn, s.isMe
                    FROM speakers s
                    JOIN meeting_speakers ms ON ms.speakerId = s.id
                    WHERE ms.meetingId = ?
                      AND EXISTS (
                          SELECT 1 FROM transcript_segments t
                          WHERE t.speakerId = s.id AND t.meetingId = ms.meetingId AND t.isExcluded = 0
                      )
                    ORDER BY s.isMe DESC, s.nameEn
                    """,
                arguments: [meetingId]
            )
            return rows.map { row in
                let name: String = row["nameEn"]
                let isMe: Bool = row["isMe"]
                return isMe ? "\(name) (\u{2605})" : name
            }
        }
    }

    /// Fetches the series name for a meeting, if any.
    ///
    /// - Parameter seriesId: The series ID.
    /// - Returns: The series name, or nil.
    package func seriesName(forId seriesId: String?) throws -> String? {
        guard let seriesId, !seriesId.isEmpty else { return nil }
        return try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT name FROM meeting_series WHERE id = ?",
                arguments: [seriesId]
            )
            return row?["name"] as? String
        }
    }

    /// Fetches the speaker name for a given speaker ID.
    ///
    /// - Parameter speakerId: The speaker ID.
    /// - Returns: The speaker name, or nil.
    package func speakerName(forId speakerId: String?) throws -> String? {
        guard let speakerId, !speakerId.isEmpty else { return nil }
        return try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT nameEn FROM speakers WHERE id = ?",
                arguments: [speakerId]
            )
            return row?["nameEn"] as? String
        }
    }

    // MARK: - Exclusion Marks

    /// Lists the exclusion marks of a meeting, ordered by start time.
    package func listMarks(meetingId: String) throws -> [MeetingMark] {
        try dbQueue.read { db in
            guard try Meeting.fetchOne(
                db,
                sql: "SELECT * FROM meetings WHERE id = ?",
                arguments: [meetingId]
            ) != nil else {
                throw MCPError.meetingNotFound(id: meetingId)
            }
            return try MeetingMark.fetchAll(
                db,
                sql: "SELECT * FROM meeting_marks WHERE meetingId = ? AND kind IN ('excluded', 'included', 'speaker', 'skipped') ORDER BY startTime",
                arguments: [meetingId]
            )
        }
    }

    // MARK: - Single Meeting

    /// Fetches a single meeting by ID.
    package func getMeeting(meetingId: String) throws -> Meeting {
        try dbQueue.read { db in
            guard let meeting = try Meeting.fetchOne(
                db,
                sql: "SELECT * FROM meetings WHERE id = ?",
                arguments: [meetingId]
            ) else {
                throw MCPError.meetingNotFound(id: meetingId)
            }
            return meeting
        }
    }

    /// Meetings whose id starts with the given prefix (CLI addressing).
    /// Compared as text, not with LIKE: the prefix is typed by a person, and
    /// `%` or `_` in it would match meetings it does not name.
    package func meetings(idPrefix: String) throws -> [Meeting] {
        try dbQueue.read { db in
            try Meeting.fetchAll(
                db,
                sql: "SELECT * FROM meetings WHERE instr(upper(id), upper(?)) = 1 ORDER BY startTime DESC",
                arguments: [idPrefix]
            )
        }
    }

    // MARK: - Meeting Series

    /// Lists all meeting series with the number of meetings attached to each.
    package func listSeries() throws -> [(series: MeetingSeries, meetingCount: Int)] {
        try dbQueue.read { db in
            let seriesList = try MeetingSeries.fetchAll(
                db,
                sql: "SELECT * FROM meeting_series ORDER BY name"
            )
            return try seriesList.map { series in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM meetings WHERE seriesId = ?",
                    arguments: [series.id]
                ) ?? 0
                return (series, count)
            }
        }
    }

}
