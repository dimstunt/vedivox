import Foundation
import VedivoxMCPLib

package struct MeetingRow: Encodable {
    package var id: String
    package var title: String
    package var startTime: String
    package var durationSeconds: Double?
    package var status: String
    package var series: String?
    package var speakers: [String]
}

package struct MeetingStateRow: Encodable {
    package var id: String
    package var title: String
    package var status: String
    package var stalled: Bool
}

package struct RecordingRow: Encodable {
    package var id: String
    package var title: String
    package var startedAt: String
    package var elapsedSeconds: Int
}

package struct StatusOverview: Encodable {
    package var appRunning: Bool
    package var recording: RecordingRow?
    package var processing: [MeetingStateRow]
}

package struct BlockRow: Encodable {
    package var speaker: String
    package var from: Double
    package var to: Double
    package var text: String
    package var segmentIds: [Int64]
}

package struct TranscriptDocument: Encodable {
    package var meeting: MeetingRow
    package var blocks: [BlockRow]
}

package struct SearchRow: Encodable {
    package var meetingId: String
    package var meetingTitle: String
    package var from: Double
    package var speaker: String?
    package var text: String
}

package struct SpeakerRow: Encodable {
    package var id: String
    package var name: String
    package var nameRu: String?
    package var nickname: String?
    package var isMe: Bool
    package var meetings: Int
}

package struct SeriesRow: Encodable {
    package var id: String
    package var name: String
    package var calendarSeriesId: String?
    package var meetings: Int
}

package struct MeetingDetailRow: Encodable {
    package var id: String
    package var title: String
    package var startTime: String
    package var durationSeconds: Double?
    package var status: String
    package var seriesId: String?
    package var series: String?
    package var speakers: [String]
    package var description: String?
    package var url: String
    /// Why the meeting needs attention or failed, comma-separated codes; absent when unknown.
    package var statusReason: String?
}

package struct MarkRow: Encodable {
    package var id: Int64?
    package var from: Double
    package var to: Double?
    package var track: String
    package var kind: String
    package var source: String
    /// The speaker a `speaker` verdict names (listen-queue); absent otherwise.
    package var speakerId: String?
    package var speakerName: String?
}

/// Command cores: pure functions the ArgumentParser shell prints from and the
/// tests call directly. Each returns the exact stdout document; everything
/// that is not data travels as a thrown CLIFailure (→ stderr + exit code).
package enum CLICommands {

    static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        // POSIX pins the Gregorian calendar: the system one can be Buddhist (year 2569).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - list

    static func meetingRow(_ meeting: Meeting, db: DatabaseReader) throws -> MeetingRow {
        MeetingRow(
            id: meeting.id,
            title: meeting.title,
            startTime: isoFormatter.string(from: meeting.startTime),
            durationSeconds: meeting.durationSeconds,
            status: meeting.status,
            series: try db.seriesName(forId: meeting.seriesId),
            speakers: try db.speakerNames(forMeeting: meeting.id)
        )
    }

    package static func list(
        statuses: [String],
        dateFrom: String?,
        dateTo: String?,
        series: String?,
        speaker: String?,
        limit: Int,
        sort: String,
        json: Bool,
        db: DatabaseReader
    ) throws -> String {
        let known = activeStatuses + ["done", "needsAttention", "error"]
        if let bad = statuses.first(where: { !known.contains($0) }) {
            throw CLIFailure(code: 64, message: "unknown status \(bad): use \(known.joined(separator: ", "))")
        }
        let meetings = try db.listMeetings(
            speaker: speaker,
            dateFrom: dateFrom,
            dateTo: dateTo,
            series: series,
            statuses: statuses.isEmpty ? ["done"] : statuses,
            limit: limit,
            sort: sort
        )
        return try meetingList(meetings, json: json, db: db)
    }

    /// The `list` document: one line per meeting, or the JSON array of `MeetingRow`.
    static func meetingList(_ meetings: [Meeting], json: Bool, db: DatabaseReader) throws -> String {
        if json {
            return try cliJSON(try meetings.map { try meetingRow($0, db: db) })
        }
        guard !meetings.isEmpty else { return "no meetings" }
        return meetings.map { meeting in
            let day = dayString(meeting.startTime)
            let duration = formatDuration(meeting.durationSeconds)
            let state = meeting.status == "done" ? duration : meeting.status
            return "\(meeting.id.prefix(8))  \(day)  \(state)  \(meeting.title)"
        }.joined(separator: "\n")
    }

    // MARK: - status

    /// Non-terminal statuses: something is (or was) being worked on.
    static let activeStatuses = ["recording", "transcribing", "diarizing"]

    /// `vedivox status` — is anything being recorded or processed right now.
    ///
    /// Liveness comes from the data-directory socket, not from the database:
    /// the stored status is the last thing written, not proof of a живой
    /// process (design § решение 10). Elapsed time counts from the meeting's
    /// own start, not from when we asked.
    package static func statusOverview(json: Bool, db: DatabaseReader, now: Date = Date()) throws -> String {
        let active = try db.listMeetings(
            speaker: nil, dateFrom: nil, dateTo: nil, series: nil,
            statuses: activeStatuses, limit: 100, sort: "newest"
        )
        let alive = try CLIRuntime.isAppServing()

        var recording: RecordingRow?
        var processing: [MeetingStateRow] = []
        for meeting in active {
            if alive, meeting.status == "recording", recording == nil {
                recording = RecordingRow(
                    id: meeting.id,
                    title: meeting.title,
                    startedAt: isoFormatter.string(from: meeting.startTime),
                    elapsedSeconds: Int(now.timeIntervalSince(meeting.startTime))
                )
            } else {
                processing.append(MeetingStateRow(
                    id: meeting.id, title: meeting.title, status: meeting.status, stalled: !alive
                ))
            }
        }
        let overview = StatusOverview(appRunning: alive, recording: recording, processing: processing)

        if json { return try cliJSON(overview) }

        var lines = ["app: \(alive ? "running" : "not running")"]
        if let recording {
            let elapsed = formatDuration(Double(recording.elapsedSeconds))
            lines.append("recording: \(recording.title) (\(recording.id.prefix(8))) — \(elapsed)")
        }
        for row in processing {
            let suffix = row.stalled ? " — stalled (app not running)" : ""
            lines.append("\(row.status): \(row.title) (\(row.id.prefix(8)))\(suffix)")
        }
        if recording == nil, processing.isEmpty {
            lines.append("idle: nothing recording or processing")
        }
        return lines.joined(separator: "\n")
    }

    /// `vedivox status <id>` — processing state of one meeting.
    package static func status(idPrefix: String, json: Bool, db: DatabaseReader) throws -> String {
        let meeting = try resolveMeeting(idPrefix: idPrefix, db: db)
        let alive = try CLIRuntime.isAppServing()
        let stalled = activeStatuses.contains(meeting.status) && !alive

        if json {
            return try cliJSON(MeetingStateRow(
                id: meeting.id, title: meeting.title, status: meeting.status, stalled: stalled
            ))
        }
        let suffix = stalled ? " — stalled (app not running)" : ""
        return "\(meeting.title): \(meeting.status)\(suffix)"
    }

    // MARK: - transcript

    package static func transcript(
        idPrefix: String,
        from: Double?,
        to: Double?,
        includeExcluded: Bool,
        json: Bool,
        db: DatabaseReader
    ) throws -> String {
        if let from, let to, to <= from {
            throw CLIFailure(code: 64, message: "--to must be greater than --from")
        }
        let meeting = try resolveMeeting(idPrefix: idPrefix, db: db)
        let (_, segments) = try db.getTranscript(
            meetingId: meeting.id, from: from, to: to, includeExcluded: includeExcluded
        )
        // Same blocks as the MCP transcript — assembly is the shared layer.
        let blocks = try assembleTranscriptBlocks(
            segments: segments,
            resolveSpeaker: makeSpeakerResolver(db: db)
        )

        if json {
            return try cliJSON(TranscriptDocument(
                meeting: try meetingRow(meeting, db: db),
                blocks: blocks.map {
                    BlockRow(speaker: $0.speaker, from: $0.startTime, to: $0.endTime, text: $0.text, segmentIds: $0.segmentIds)
                }
            ))
        }

        var lines = ["\(meeting.title) — \(dayString(meeting.startTime))", ""]
        for block in blocks {
            let start = formatTimestamp(block.startTime)
            let end = formatTimestamp(block.endTime)
            lines.append("[\(start) → \(end)] \(block.speaker): \(block.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - search

    package static func search(
        query: String,
        limit: Int,
        includeExcluded: Bool,
        meetings: Bool = false,
        json: Bool,
        db: DatabaseReader
    ) throws -> String {
        if meetings {
            let found = try db.searchMeetings(query: query, limit: limit, includeExcluded: includeExcluded)
            return try meetingList(found, json: json, db: db)
        }
        let results = try db.searchTranscripts(query: query, limit: limit, includeExcluded: includeExcluded)
        let rows = results.map { result in
            SearchRow(
                meetingId: result.segment.meetingId,
                meetingTitle: result.meetingTitle,
                from: result.segment.startTime,
                speaker: result.segment.speakerLabel,
                text: result.segment.text
            )
        }
        if json { return try cliJSON(rows) }
        guard !rows.isEmpty else { return "no matches" }
        return rows.map { row in
            "[\(row.meetingTitle) \(formatTimestamp(row.from))] \(row.speaker ?? "?"): \(row.text)"
        }.joined(separator: "\n")
    }

    // MARK: - speakers

    package static func speakers(meetingIdPrefix: String?, json: Bool, db: DatabaseReader) throws -> String {
        let meetingId = try meetingIdPrefix.map { try resolveMeeting(idPrefix: $0, db: db).id }
        let results = try db.listSpeakers(meetingId: meetingId)
        let rows = results.map { entry in
            SpeakerRow(
                id: entry.speaker.id,
                name: entry.speaker.nameEn,
                nameRu: entry.speaker.nameRu,
                nickname: entry.speaker.nickname,
                isMe: entry.speaker.isMe,
                meetings: entry.meetingCount
            )
        }
        if json { return try cliJSON(rows) }
        guard !rows.isEmpty else { return "no speakers" }
        return rows.map { row in
            let star = row.isMe ? " (me)" : ""
            // The whole id: speaker commands do not resolve prefixes.
            return "\(row.id)  \(row.name)\(star) — \(row.meetings)"
        }.joined(separator: "\n")
    }

    // MARK: - series

    package static func series(json: Bool, db: DatabaseReader) throws -> String {
        let rows = try db.listSeries().map { entry in
            SeriesRow(
                id: entry.series.id,
                name: entry.series.name,
                calendarSeriesId: entry.series.calendarSeriesId,
                meetings: entry.meetingCount
            )
        }
        if json { return try cliJSON(rows) }
        guard !rows.isEmpty else { return "no series" }
        return rows.map { "\($0.id)  \($0.name) — \($0.meetings)" }.joined(separator: "\n")
    }

    // MARK: - show

    /// One meeting in full — what the app's detail pane knows: series and the
    /// stored description included, so an enrichment can see what is already there.
    package static func show(idPrefix: String, json: Bool, db: DatabaseReader) throws -> String {
        let meeting = try resolveMeeting(idPrefix: idPrefix, db: db)
        let row = MeetingDetailRow(
            id: meeting.id,
            title: meeting.title,
            startTime: isoFormatter.string(from: meeting.startTime),
            durationSeconds: meeting.durationSeconds,
            status: meeting.status,
            seriesId: meeting.seriesId,
            series: try db.seriesName(forId: meeting.seriesId),
            speakers: try db.speakerNames(forMeeting: meeting.id),
            description: meeting.description,
            url: "vedivox://meeting/\(meeting.id)",
            statusReason: meeting.statusReason
        )
        if json { return try cliJSON(row) }
        var lines = [
            "\(row.id)  \(row.title)",
            "\(row.startTime)  \(formatDuration(row.durationSeconds))  \(row.status)",
        ]
        if let reason = row.statusReason { lines.append("reason: \(reason)") }
        if let series = row.series { lines.append("series: \(series) (\(row.seriesId ?? ""))") }
        if !row.speakers.isEmpty { lines.append("speakers: \(row.speakers.joined(separator: ", "))") }
        lines.append(row.url)
        if let description = row.description, !description.isEmpty {
            lines.append("")
            lines.append(description)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - marks

    package static func marks(idPrefix: String, json: Bool, db: DatabaseReader) throws -> String {
        let meeting = try resolveMeeting(idPrefix: idPrefix, db: db)
        let rows = try db.listMarks(meetingId: meeting.id).map { mark in
            MarkRow(
                id: mark.id, from: mark.startTime, to: mark.endTime, track: mark.track, kind: mark.kind,
                source: mark.source, speakerId: mark.speakerId, speakerName: try db.speakerName(forId: mark.speakerId)
            )
        }
        if json { return try cliJSON(rows) }
        guard !rows.isEmpty else { return "no marks" }
        return rows.map { row in
            let end = row.to.map { formatTimestamp($0) } ?? "open"
            let who = row.speakerId.map { "  → \(row.speakerName ?? "?") (\($0))" } ?? ""
            return "#\(row.id.map(String.init) ?? "?")  [\(formatTimestamp(row.from)) → \(end)]  \(row.track)  \(row.kind) (\(row.source))\(who)"
        }.joined(separator: "\n")
    }
}
