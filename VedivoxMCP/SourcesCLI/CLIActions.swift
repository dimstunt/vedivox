import ArgumentParser
import Foundation
import VedivoxMCPLib

/// Action commands (wave 2): each sends a command over the data-directory
/// socket and reports the APP's outcome, never the delivery (spec: «Команда
/// действия отчитывается о выполнении»). Exit code comes from the response.
enum CLIActionCore {

    /// Sends a request and renders the app's answer; a refusal becomes the
    /// matching exit code via `cliFailure(from:)`.
    static func send(_ request: AppCommandRequest) throws -> String {
        let response = try CLIRuntime.sendCommand(request)
        if let failure = cliFailure(from: response) { throw failure }
        return response.message
    }

    static func importFile(path: String, title: String?, date: String?) throws -> String {
        // Same fast-fail validation the MCP tool applies, via the shared tool
        // entry: one place decides what a valid import request is.
        var params: [String: AnyCodable] = ["file_path": .string(path)]
        if let title { params["title"] = .string(title) }
        if let date { params["date"] = .string(date) }
        return try withCLIDispatch { try ImportFileTool.run(params: params) }
    }

    static func importYouTube(url: String, title: String?, date: String?) throws -> String {
        var params: [String: AnyCodable] = ["url": .string(url)]
        if let title { params["title"] = .string(title) }
        if let date { params["date"] = .string(date) }
        return try withCLIDispatch { try ImportYouTubeTool.run(params: params) }
    }

    /// A path as the user typed it, made absolute for the app. A quoted `~/x`
    /// reaches us unexpanded, so the tilde is ours to resolve.
    static func absolutePath(_ source: String) -> String {
        let path = (source as NSString).expandingTildeInPath
        return (path as NSString).isAbsolutePath ? path : FileManager.default.currentDirectoryPath + "/" + path
    }

    /// One transcribed segment as the app sends it; also the `--json` row.
    struct TranscribedRow: Codable {
        let speaker: String
        let from: Double
        let to: Double
        let text: String
    }

    /// `vedivox transcribe`: the app transcribes and diarizes, nothing is stored.
    /// A YouTube download is deleted once the app has answered.
    static func transcribe(source: String, json: Bool) throws -> String {
        var path = source
        var downloaded: ImportYouTubeTool.DownloadResult?
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            do {
                let download = try ImportYouTubeTool.fetchAudio(source)
                downloaded = download
                path = download.filePath
            } catch {
                throw CLIFailure.refusal(error.message)
            }
        } else {
            path = absolutePath(source)
            let ext = (path as NSString).pathExtension.lowercased()
            guard ImportFileTool.supportedExtensions.contains(ext) else {
                throw CLIFailure(code: 64, message: "unsupported format .\(ext). Supported: "
                    + ImportFileTool.supportedExtensions.sorted().joined(separator: ", "))
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw CLIFailure.notFound("file not found at \(path)")
            }
        }
        defer { downloaded?.discard() }

        let response = try CLIRuntime.sendCommand(
            AppCommandRequest(command: AppCommandName.transcribeFile, params: ["path": path])
        )
        if let failure = cliFailure(from: response) { throw failure }
        let rows = try JSONDecoder().decode(
            [TranscribedRow].self, from: Data((response.data?["segments"] ?? "[]").utf8)
        )
        if json { return try cliJSON(rows) }
        return mergeTurns(rows).map {
            "[\(formatTimestamp($0.from)) → \(formatTimestamp($0.to))] \($0.speaker): \($0.text)"
        }.joined(separator: "\n")
    }

    /// Same reading unit as `vedivox transcript`: consecutive rows of one speaker
    /// within 20 s become one line (assembleTranscriptBlocks' mergeGap).
    static func mergeTurns(_ rows: [TranscribedRow]) -> [TranscribedRow] {
        rows.reduce(into: []) { turns, row in
            if let last = turns.last, last.speaker == row.speaker, row.from - last.to <= 20 {
                turns[turns.count - 1] = TranscribedRow(
                    speaker: last.speaker, from: last.from, to: row.to, text: last.text + " " + row.text
                )
            } else {
                turns.append(row)
            }
        }
    }

    /// Runs an MCP import tool as the CLI's engine. The tools already own the
    /// whole flow (validation, yt-dlp, handing the file to the app); their
    /// failure convention — a returned string with the "Error: " prefix — is
    /// pinned verbatim by ToolTests.
    ///
    /// ponytail: prefix check instead of a typed result across the import
    /// tools; give them typed results if a third consumer appears.
    static func withCLIDispatch(_ body: () throws -> String) throws -> String {
        let text = try body()
        if text.hasPrefix("Error: ") {
            let message = String(text.dropFirst("Error: ".count))
            // The app's refusals end with its reason in brackets (AppCommandDispatch.describe).
            if message.contains("not found at ") || message.hasSuffix("[not_found]") {
                throw CLIFailure.notFound(message)
            }
            if message.hasSuffix("[invalid_parameters]") {
                throw CLIFailure(code: 64, message: message)
            }
            // Every AppCommandError description: the app could not be reached.
            if ["is not answering", "could not launch", "access to the Vedivox socket",
                "exchange with Vedivox failed", "socket path is longer"].contains(where: message.contains) {
                throw CLIFailure.unavailable(message)
            }
            throw CLIFailure.refusal(message)
        }
        return text
    }

    static func reprocess(meetingId: String, suppressEcho: Bool?, confirmed: Bool, db: DatabaseReader) throws -> String {
        let meeting = try resolveMeeting(idPrefix: meetingId, db: db)
        guard confirmed else {
            throw CLIFailure.refusal(
                "pass --yes to reprocess (the transcript and speaker attribution are rebuilt from the audio):\n"
                    + "  \(meeting.id.prefix(8))  \(meeting.title)"
            )
        }
        var params = ["meeting_id": meeting.id]
        // Absent means autodetect — only sent when the caller chose.
        if let suppressEcho { params["suppress_echo"] = suppressEcho ? "1" : "0" }
        return try send(AppCommandRequest(command: AppCommandName.reprocessMeeting, params: params))
    }

    static func speakerRename(speakerId: String, name: String, confirmed: Bool) throws -> String {
        var params = ["speaker_id": speakerId, "name": name]
        // The app only confirms and rebuilds the canonical when asked (AppState.commandUpdateSpeaker).
        if confirmed { params["confirmed"] = "1" }
        return try send(AppCommandRequest(command: AppCommandName.updateSpeaker, params: params))
    }

    static func speakerMerge(targetId: String, sourceIds: [String], confirmed: Bool, db: DatabaseReader) throws -> String {
        let request: AppCommandRequest
        do {
            request = try AppCommandBuilders.mergeSpeakers(targetId: targetId, sourceIds: sourceIds)
        } catch let error as AppCommandBuilders.BuildError {
            throw CLIFailure(code: 64, message: error.description)
        }
        // Like reprocess and speaker delete: a missing speaker is "not found" (2) before the --yes question.
        if let missing = try ([targetId] + sourceIds).first(where: { try db.speakerName(forId: $0) == nil }) {
            throw CLIFailure.notFound("no speaker with id \(missing)")
        }
        guard confirmed else {
            throw CLIFailure.refusal(
                "pass --yes to merge (the source speakers are deleted, their lines go to the target):\n"
                    + "  \(sourceIds.joined(separator: ", ")) → \(targetId)"
            )
        }
        return try send(request)
    }

    static func speakerDetach(speakerId: String, meetingPrefixes: [String], db: DatabaseReader) throws -> String {
        // Every prefix must resolve before anything is sent: an ambiguous
        // meeting id on a data change must not detach "most of them".
        let meetingIds = try meetingPrefixes.map { try resolveMeeting(idPrefix: $0, db: db).id }
        guard !meetingIds.isEmpty else { throw CLIFailure(code: 64, message: "meeting_ids must not be empty") }
        // The app moves the speaker's lines in each meeting to a fresh anonymous record (apply-anon-identification).
        return try send(AppCommandRequest(
            command: AppCommandName.detachMeetings,
            params: ["speaker_id": speakerId, "meeting_ids": meetingIds.joined(separator: ",")]
        ))
    }

    /// `vedivox speaker delete`: without `--yes` it only says what would happen.
    static func speakerDelete(speakerId: String, confirmed: Bool, db: DatabaseReader) throws -> String {
        guard let name = try db.speakerName(forId: speakerId) else {
            throw CLIFailure.notFound("no speaker with id \(speakerId)")
        }
        guard confirmed else {
            throw CLIFailure.refusal(
                "pass --yes to delete \(name) (\(speakerId)): their lines in every meeting become unnamed, "
                    + "their verdicts are dropped and the voice is forgotten"
            )
        }
        return try send(AppCommandRequest(command: AppCommandName.deleteSpeaker, params: ["speaker_id": speakerId]))
    }

    static func meetingSet(
        meetingId: String,
        title: String?,
        description: String?,
        seriesId: String?,
        db: DatabaseReader
    ) throws -> String {
        guard title != nil || description != nil || seriesId != nil else {
            throw CLIFailure(code: 64, message: "nothing to change: pass --title, --description or --series-id")
        }
        let meeting = try resolveMeeting(idPrefix: meetingId, db: db)
        var params = ["meeting_id": meeting.id]
        if let title { params["title"] = title }
        if let description { params["description"] = description }
        if let seriesId { params["series_id"] = seriesId }
        return try send(AppCommandRequest(command: AppCommandName.updateMeeting, params: params))
    }

    /// `vedivox meeting delete`: every prefix resolves before anything is sent, and
    /// without `--yes` it only lists what would go.
    static func meetingDelete(meetingIds: [String], confirmed: Bool, json: Bool, db: DatabaseReader) throws -> String {
        guard !meetingIds.isEmpty else { throw CLIFailure(code: 64, message: "no meeting id given") }
        var seen = Set<String>()
        let meetings = try meetingIds
            .map { try resolveMeeting(idPrefix: $0, db: db) }
            .filter { seen.insert($0.id).inserted }
        let listing = meetings.map { "\($0.id.prefix(8))  \($0.title)" }
        guard confirmed else {
            throw CLIFailure.refusal(
                "pass --yes to delete (audio goes to the Trash, the transcript is deleted):\n"
                    + listing.map { "  " + $0 }.joined(separator: "\n")
            )
        }
        let ids = meetings.map(\.id)
        // Meeting ids are UUIDs, so a comma cannot occur inside one.
        _ = try send(AppCommandRequest(
            command: AppCommandName.deleteMeetings, params: ["meeting_ids": ids.joined(separator: ",")]
        ))
        if json { return try cliJSON(["deleted": ids]) }
        return listing.map { "deleted " + $0 }.joined(separator: "\n")
    }

    // MARK: Split, trim, merge and undo (cli-meeting-edit)

    /// A chain stopped midway: the app's refusal, after what was already done.
    static func chainFailure(_ stop: MeetingEdits.ChainStopped) -> CLIFailure {
        let failure = cliFailure(from: stop.response) ?? .refusal(stop.response.message)
        guard !stop.done.isEmpty else { return failure }
        let done = stop.done.map { "  " + $0 }.joined(separator: "\n")
        return CLIFailure(code: failure.code, message: "already done:\n\(done)\nthen refused: \(failure.message)")
    }

    static func listing(_ ids: [String], db: DatabaseReader) -> String {
        ids.map { id in "  \(id.prefix(8))  \((try? db.getMeeting(meetingId: id).title) ?? "")" }.joined(separator: "\n")
    }

    /// `vedivox meeting split`: every point is checked before the first cut,
    /// and without `--yes` the parts are only listed.
    static func meetingSplit(meetingId: String, at times: [Double], confirmed: Bool, json: Bool, db: DatabaseReader) throws -> String {
        let meeting = try resolveMeeting(idPrefix: meetingId, db: db)
        let starts = try db.getTranscript(meetingId: meeting.id, includeExcluded: true).segments.map(\.startTime)
        let duration = meeting.durationSeconds ?? 0
        if let why = MeetingEdits.splitRefusal(at: times, duration: duration, lineStarts: starts) {
            throw CLIFailure(code: 64, message: "cannot split “\(meeting.title)”: \(why)")
        }
        let parts = MeetingEdits.splitParts(at: times, duration: duration, lineStarts: starts)
        guard confirmed else {
            let rows = parts.enumerated().map { index, part in
                "  part \(index + 1)  \(MeetingEdits.clock(part.from))–\(MeetingEdits.clock(part.to))  \(part.lines) lines"
            }
            throw CLIFailure.refusal(
                "pass --yes to split \(meeting.id.prefix(8)) “\(meeting.title)” into \(parts.count) meetings "
                    + "(it stays the first part):\n" + rows.joined(separator: "\n")
            )
        }
        let ids: [String]
        do {
            ids = try MeetingEdits.split(meetingId: meeting.id, at: times, send: CLIRuntime.sendCommand)
        } catch let stop as MeetingEdits.ChainStopped {
            throw chainFailure(stop)
        }
        if json { return try cliJSON(["meetings": ids]) }
        return "split into:\n" + listing(ids, db: db)
    }

    static func meetingTrim(meetingId: String, from: Double?, to: Double?, confirmed: Bool, json: Bool, db: DatabaseReader) throws -> String {
        guard from != nil || to != nil else { throw CLIFailure(code: 64, message: "nothing to trim: pass --from, --to or both") }
        let meeting = try resolveMeeting(idPrefix: meetingId, db: db)
        let duration = meeting.durationSeconds ?? 0
        let (keepFrom, keepTo) = (from ?? 0, to ?? duration)
        guard confirmed else {
            let segments = try db.getTranscript(meetingId: meeting.id, includeExcluded: true).segments
            let dropped = segments.filter { $0.endTime <= keepFrom || $0.startTime >= keepTo }.count
            throw CLIFailure.refusal(
                "pass --yes to trim \(meeting.id.prefix(8)) “\(meeting.title)” to "
                    + "\(MeetingEdits.clock(keepFrom))–\(MeetingEdits.clock(keepTo)) of \(MeetingEdits.clock(duration)); "
                    + "\(dropped) of \(segments.count) lines are dropped"
            )
        }
        let response = try MeetingEdits.trim(meetingId: meeting.id, from: keepFrom, to: keepTo, send: CLIRuntime.sendCommand)
        if let failure = cliFailure(from: response) { throw failure }
        if json { return try cliJSON(["meeting": meeting.id]) }
        return response.message
    }

    /// `vedivox meeting merge`: in order of start, into the earliest meeting.
    static func meetingMerge(meetingIds: [String], confirmed: Bool, json: Bool, db: DatabaseReader) throws -> String {
        var seen = Set<String>()
        let meetings = try meetingIds
            .map { try resolveMeeting(idPrefix: $0, db: db) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.startTime < $1.startTime }
        guard meetings.count >= 2 else { throw CLIFailure(code: 64, message: "merge needs at least two different meetings") }
        guard confirmed else {
            let rows = meetings.map { "  \($0.id.prefix(8))  \(CLICommands.dayString($0.startTime))  \($0.title)" }
            throw CLIFailure.refusal(
                "pass --yes to merge, in order of start, into \(meetings[0].id.prefix(8)) “\(meetings[0].title)”:\n"
                    + rows.joined(separator: "\n")
            )
        }
        let result: (meeting: String, merged: [String])
        do {
            result = try MeetingEdits.merge(meetingIds: meetings.map(\.id), send: CLIRuntime.sendCommand)
        } catch let stop as MeetingEdits.ChainStopped {
            throw chainFailure(stop)
        }
        if json { return try cliJSON(MergeResult(meeting: result.meeting, merged: result.merged)) }
        return "merged into:\n" + listing([result.meeting], db: db)
    }

    struct MergeResult: Encodable {
        let meeting: String
        let merged: [String]
    }

    private static let undoWarnings = [
        "split": "the parts become one meeting again; the later part's title and description are lost",
        "trim": "the cut audio comes back and the meeting is reprocessed; text and speaker edits are lost",
        "merge": "the merged meeting is split back into the two it was made of",
    ]

    /// `vedivox meeting undo`: the last split, trim or merge of a meeting; a
    /// split is undone from either part.
    static func meetingUndo(kind: String, meetingId: String, confirmed: Bool, json: Bool, db: DatabaseReader) throws -> String {
        guard let warning = undoWarnings[kind] else {
            throw CLIFailure(code: 64, message: "unknown kind \(kind): use split, trim or merge")
        }
        let meeting = try resolveMeeting(idPrefix: meetingId, db: db)
        guard confirmed else {
            throw CLIFailure.refusal(
                "pass --yes to undo the last \(kind) of \(meeting.id.prefix(8)) “\(meeting.title)”: \(warning)"
            )
        }
        let response = try MeetingEdits.undo(kind, meetingId: meeting.id, send: CLIRuntime.sendCommand)
        if let failure = cliFailure(from: response) { throw failure }
        let ids = MeetingEdits.ids(response, "meeting_ids")
        if json { return try cliJSON(["meetings": ids.isEmpty ? [meeting.id] : ids]) }
        return response.message
    }

    static func markExcluded(meetingId: String, from: Double, to: Double, track: String?, db: DatabaseReader) throws -> String {
        guard to > from else { throw CLIFailure(code: 64, message: "--to must be greater than --from") }
        let meeting = try resolveMeeting(idPrefix: meetingId, db: db)
        var params = ["meeting_id": meeting.id, "from": String(from), "to": String(to)]
        if let track { params["track"] = track }
        return try send(AppCommandRequest(command: AppCommandName.markExcluded, params: params))
    }

    static func unmark(
        meetingId: String, markId: Int64?, from: Double?, to: Double?, track: String?, db: DatabaseReader
    ) throws -> String {
        // Argument shape first (64), meeting lookup second (2): a bad call on a
        // missing meeting must still read as a bad call.
        var params: [String: String] = [:]
        if let markId {
            params["mark_id"] = String(markId)
        } else {
            guard let from, let to, to > from else {
                throw CLIFailure(code: 64, message: "pass --id, or --from and --to with to greater than from")
            }
            params["from"] = String(from)
            params["to"] = String(to)
            if let track { params["track"] = track }
        }
        params["meeting_id"] = try resolveMeeting(idPrefix: meetingId, db: db).id
        return try send(AppCommandRequest(command: AppCommandName.unmark, params: params))
    }

    static func segmentSet(segmentId: Int64, speakerId: String) throws -> String {
        try send(AppCommandRequest(
            command: AppCommandName.updateSegment,
            params: ["segment_id": String(segmentId), "speaker_id": speakerId]
        ))
    }

    static func seriesCreate(name: String, calendarSeriesId: String?) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIFailure(code: 64, message: "series name is empty")
        }
        var params = ["name": name]
        if let calendarSeriesId { params["calendar_series_id"] = calendarSeriesId }
        return try send(AppCommandRequest(command: AppCommandName.createSeries, params: params))
    }

    static func seriesSet(
        seriesId: String, name: String?, calendarSeriesId: String?, autoRule: String?, db: DatabaseReader
    ) throws -> String {
        guard name != nil || calendarSeriesId != nil || autoRule != nil else {
            throw CLIFailure(code: 64, message: "nothing to change: pass --name, --calendar-series-id or --auto-rule")
        }
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIFailure(code: 64, message: "series name is empty")
        }
        var params = ["series_id": try resolveSeries(idPrefix: seriesId, db: db).id]
        if let name { params["name"] = name }
        if let calendarSeriesId { params["calendar_series_id"] = calendarSeriesId }
        if let autoRule { params["auto_rule_pattern"] = autoRule }
        return try send(AppCommandRequest(command: AppCommandName.updateSeries, params: params))
    }

    /// `vedivox series apply-rules`: without `--yes` the app only counts, and the
    /// count comes back as a refusal so a script cannot mistake it for done.
    static func seriesApplyRules(confirmed: Bool) throws -> String {
        guard confirmed else {
            let response = try CLIRuntime.sendCommand(AppCommandRequest(
                command: AppCommandName.applySeriesRules, params: ["dry_run": "1"]
            ))
            if let failure = cliFailure(from: response) { throw failure }
            guard response.data?["assigned"] != "0" else { return response.message }
            throw CLIFailure.refusal(response.message + "\npass --yes to assign them")
        }
        // The app treats anything but an explicit "0" as a dry run.
        return try send(AppCommandRequest(command: AppCommandName.applySeriesRules, params: ["dry_run": "0"]))
    }

    /// `vedivox series merge`: without `--yes` names both series and what would
    /// move, read from the database — nothing is sent to the app.
    static func seriesMerge(sourceId: String, targetId: String, confirmed: Bool, db: DatabaseReader) throws -> String {
        let source = try resolveSeries(idPrefix: sourceId, db: db)
        let target = try resolveSeries(idPrefix: targetId, db: db)
        guard source.id != target.id else {
            throw CLIFailure(code: 64, message: "the series to merge and the one to keep are the same series")
        }
        guard confirmed else {
            let moving = try db.listSeries().first { $0.series.id == source.id }?.meetingCount ?? 0
            var plan = "pass --yes to merge (\(moving) meetings move, then the first series is deleted):\n"
                + "  \(source.id.prefix(8))  \(source.name)\n"
                + "  → \(target.id.prefix(8))  \(target.name)"
            if let theirs = source.calendarSeriesId, target.calendarSeriesId != nil {
                plan += "\nboth are linked to a calendar event; \(target.name) keeps its own, \(theirs) is dropped"
            }
            throw CLIFailure.refusal(plan)
        }
        return try send(AppCommandRequest(
            command: AppCommandName.mergeSeries, params: ["source_id": source.id, "target_id": target.id]
        ))
    }

    static func seriesDelete(seriesId: String, confirmed: Bool, db: DatabaseReader) throws -> String {
        let series = try resolveSeries(idPrefix: seriesId, db: db)
        guard confirmed else {
            throw CLIFailure.refusal(
                "pass --yes to delete the series (its meetings stay, without the series):\n"
                    + "  \(series.id.prefix(8))  \(series.name)"
            )
        }
        return try send(AppCommandRequest(command: AppCommandName.deleteSeries, params: ["series_id": series.id]))
    }
}

// MARK: - ArgumentParser shells

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import an audio/video file or a YouTube URL as a meeting."
    )

    @Argument(help: "Path to a media file, or a YouTube URL.")
    var source: String

    @Option(help: "Meeting title.")
    var title: String?

    @Option(help: "Meeting date (YYYY-MM-DD or ISO8601).")
    var date: String?

    func run() throws {
        try executeCore {
            if source.hasPrefix("http://") || source.hasPrefix("https://") {
                return try CLIActionCore.importYouTube(url: source, title: title, date: date)
            }
            return try CLIActionCore.importFile(path: CLIActionCore.absolutePath(source), title: title, date: date)
        }
    }
}

struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe and diarize a file or a YouTube URL without saving anything to Vedivox."
    )

    @Argument(help: "Path to a media file, or a YouTube URL.")
    var source: String

    @Flag(help: "Machine output: one JSON array of {speaker, from, to, text}.")
    var json = false

    func run() throws {
        try executeCore { try CLIActionCore.transcribe(source: source, json: json) }
    }
}

struct Reprocess: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reprocess",
        abstract: "Re-transcribe and re-diarize a meeting; reports the actual outcome."
    )

    @Argument(help: "Meeting id or its unambiguous prefix.")
    var meetingId: String

    @Flag(name: .customLong("suppress-echo"), inversion: .prefixedNo, help: "Force echo suppression on or off; omit to autodetect.")
    var suppressEcho: Bool?

    @Flag(help: "Actually reprocess; without it the command only names the meeting.") var yes = false

    func run() throws {
        try executeCore { db in
            try CLIActionCore.reprocess(meetingId: meetingId, suppressEcho: suppressEcho, confirmed: yes, db: db)
        }
    }
}

struct SpeakerCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speaker",
        abstract: "Speaker data changes (run through the app).",
        subcommands: [Rename.self, Merge.self, Detach.self, Delete.self]
    )

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rename", abstract: "Rename a speaker."
        )

        @Argument(help: "Speaker id.") var speakerId: String
        @Argument(help: "New name.") var name: String
        @Flag(name: .long, help: "Also confirm the speaker and rebuild their canonical embedding.")
        var confirmed = false

        func run() throws {
            try executeCore {
                try CLIActionCore.speakerRename(speakerId: speakerId, name: name, confirmed: confirmed)
            }
        }
    }

    struct Merge: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "merge", abstract: "Merge source speakers into a target."
        )

        @Argument(help: "Target speaker id (kept).") var targetId: String
        @Argument(help: "Source speaker ids (merged and deleted).") var sourceIds: [String]
        @Flag(help: "Actually merge; without it the command only names what would merge.") var yes = false

        func run() throws {
            try executeCore { db in
                try CLIActionCore.speakerMerge(targetId: targetId, sourceIds: sourceIds, confirmed: yes, db: db)
            }
        }
    }

    struct Detach: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "detach",
            abstract: "Take meetings away from a speaker record (apply-anon-identification)."
        )

        @Argument(help: "Speaker id.") var speakerId: String
        @Argument(help: "Meeting ids or unambiguous prefixes.") var meetings: [String]

        func run() throws {
            try executeCore { db in
                try CLIActionCore.speakerDetach(speakerId: speakerId, meetingPrefixes: meetings, db: db)
            }
        }
    }
}

extension SpeakerCmd {
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a speaker: their lines become unnamed, verdicts and the voice go."
        )

        @Argument(help: "Speaker id.") var speakerId: String
        @Flag(help: "Actually delete; without it the command only says what would happen.") var yes = false

        func run() throws {
            try executeCore { db in try CLIActionCore.speakerDelete(speakerId: speakerId, confirmed: yes, db: db) }
        }
    }
}

struct MeetingCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meeting",
        abstract: "Meeting changes, deletion, split, trim, merge and their undo (run through the app).",
        subcommands: [
            SetMeeting.self, DeleteMeeting.self, PinSpeakers.self,
            SplitMeeting.self, TrimMeeting.self, MergeMeetings.self, UndoMeetingEdit.self,
        ]
    )

    struct SplitMeeting: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "split",
            abstract: "Cut a meeting into parts, as Split in the app does; the meeting stays the first part.",
            discussion: """
                Points are seconds from the start of the recording, as `from` in `transcript --json`. \
                Several points cut from the last back, so all stay on the original timeline. \
                Only the last cut can be undone.
                """
        )

        @Argument(help: "Meeting id or its unambiguous prefix.") var meetingId: String
        @Option(name: .customLong("at"), help: "Cut point in seconds; repeat for several.") var at: [Double] = []
        @Flag(help: "Actually split; without it the command only lists the parts.") var yes = false
        @Flag(help: "Machine output: {\"meetings\": [ids in time order]}.") var json = false

        func run() throws {
            try executeCore { db in
                try CLIActionCore.meetingSplit(meetingId: meetingId, at: at, confirmed: yes, json: json, db: db)
            }
        }
    }

    struct TrimMeeting: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "trim",
            abstract: "Keep only a stretch of a meeting, as Trim in the app does."
        )

        @Argument(help: "Meeting id or its unambiguous prefix.") var meetingId: String
        @Option(help: "Keep from this second (default: the start).") var from: Double?
        @Option(help: "Keep up to this second (default: the end).") var to: Double?
        @Flag(help: "Actually trim; without it the command only says what goes.") var yes = false
        @Flag(help: "Machine output: {\"meeting\": id}.") var json = false

        func run() throws {
            try executeCore { db in
                try CLIActionCore.meetingTrim(meetingId: meetingId, from: from, to: to, confirmed: yes, json: json, db: db)
            }
        }
    }

    struct MergeMeetings: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "merge",
            abstract: "Join meetings into the earliest one, in order of start, as Merge Meetings in the app does.",
            discussion: "Three or more are joined pairwise; only the last join can be undone."
        )

        @Argument(help: "Meeting ids or unambiguous prefixes, two or more.") var meetingIds: [String]
        @Flag(help: "Actually merge; without it the command only lists the meetings.") var yes = false
        @Flag(help: "Machine output: {\"meeting\": id that stays, \"merged\": [ids joined into it]}.") var json = false

        func run() throws {
            try executeCore { db in
                try CLIActionCore.meetingMerge(meetingIds: meetingIds, confirmed: yes, json: json, db: db)
            }
        }
    }

    struct UndoMeetingEdit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "undo",
            abstract: "Undo the last split, trim or merge of a meeting, as the Undo buttons in the app do.",
            discussion: "A split is undone from either part. Undoing a trim reprocesses the meeting and waits for it."
        )

        @Argument(help: "split, trim or merge.") var kind: String
        @Argument(help: "Meeting id or its unambiguous prefix.") var meetingId: String
        @Flag(help: "Actually undo; without it the command only says what would change.") var yes = false
        @Flag(help: "Machine output: {\"meetings\": [ids]}.") var json = false

        func run() throws {
            try executeCore { db in
                try CLIActionCore.meetingUndo(kind: kind, meetingId: meetingId, confirmed: yes, json: json, db: db)
            }
        }
    }

    struct DeleteMeeting: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete meetings like the app does: audio to the Trash, transcript out of the database."
        )

        @Argument(help: "Meeting ids or unambiguous prefixes.") var meetingIds: [String]
        @Flag(help: "Actually delete; without it the command only lists what would go.") var yes = false
        @Flag(help: "Machine output: {\"deleted\": [ids]}.") var json = false

        func run() throws {
            try executeCore { db in
                try CLIActionCore.meetingDelete(meetingIds: meetingIds, confirmed: yes, json: json, db: db)
            }
        }
    }

    struct SetMeeting: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Set title, description or series of a meeting."
        )

        @Argument(help: "Meeting id or its unambiguous prefix.") var meetingId: String
        @Option(help: "New title.") var title: String?
        @Option(help: "New description (empty string clears).") var description: String?
        @Option(name: .customLong("series-id"), help: "Series id (empty string unlinks).") var seriesId: String?

        func run() throws {
            try executeCore { db in
                try CLIActionCore.meetingSet(
                    meetingId: meetingId, title: title, description: description,
                    seriesId: seriesId, db: db
                )
            }
        }
    }
}

struct Marks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "marks",
        abstract: "Exclusion marks of a meeting: excluded / included intervals per track."
    )

    @Argument(help: "Meeting id or its unambiguous prefix.") var meetingId: String
    @Flag(help: "Machine output: one JSON array.") var json = false

    func run() throws {
        try executeCore { db in try CLICommands.marks(idPrefix: meetingId, json: json, db: db) }
    }
}

struct Mark: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mark",
        abstract: "Exclude a time interval from the transcript (reversible, see unmark)."
    )

    @Argument(help: "Meeting id or its unambiguous prefix.") var meetingId: String
    @Option(name: .customLong("from"), help: "Interval start in seconds.") var from: Double
    @Option(name: .customLong("to"), help: "Interval end in seconds.") var to: Double
    @Option(help: "Track: mic (default), system, merged or import.") var track: String?

    func run() throws {
        try executeCore { db in
            try CLIActionCore.markExcluded(meetingId: meetingId, from: from, to: to, track: track, db: db)
        }
    }
}

struct Unmark: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unmark",
        abstract: "Undo an exclusion: delete a mark by --id, or bring --from/--to back into the transcript."
    )

    @Argument(help: "Meeting id or its unambiguous prefix.") var meetingId: String
    @Option(name: .customLong("id"), help: "Mark id (see `vedivox marks`).") var markId: Int64?
    @Option(name: .customLong("from"), help: "Range start in seconds.") var from: Double?
    @Option(name: .customLong("to"), help: "Range end in seconds.") var to: Double?
    @Option(help: "Track for the range form: mic (default), system, merged or import.") var track: String?

    func run() throws {
        try executeCore { db in
            try CLIActionCore.unmark(meetingId: meetingId, markId: markId, from: from, to: to, track: track, db: db)
        }
    }
}

struct SegmentCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "segment",
        abstract: "Transcript segment changes (run through the app).",
        subcommands: [SetSegment.self]
    )

    struct SetSegment: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Reassign a segment, or every line of a time range, to a speaker; the verdict survives reprocess."
        )

        @Argument(help: "Segment id (see `vedivox transcript --json`), or with --from/--to a meeting id or prefix.")
        var target: String
        @Option(help: "Speaker id to assign.") var speaker: String
        @Option(name: .customLong("from"), help: "Range start in seconds (range form).") var from: Double?
        @Option(name: .customLong("to"), help: "Range end in seconds (range form).") var to: Double?
        @Option(help: "Range form: only this track (mic, system, merged, import); every track when omitted.")
        var track: String?

        func run() throws {
            try executeCore {
                switch (from, to) {
                case (nil, nil):
                    guard track == nil else { throw CLIFailure(code: 64, message: "--track needs --from and --to") }
                    guard let segmentId = Int64(target) else {
                        throw CLIFailure(code: 64, message: "segment id must be an integer; for a range pass --from and --to")
                    }
                    return try CLIActionCore.segmentSet(segmentId: segmentId, speakerId: speaker)
                case (let from?, let to?):
                    let db = try DatabaseReader()
                    return try CLIListenCore.assignRange(
                        meeting: target, from: from, to: to, track: track, speakerId: speaker, db: db
                    )
                default:
                    throw CLIFailure(code: 64, message: "pass both --from and --to")
                }
            }
        }
    }
}
