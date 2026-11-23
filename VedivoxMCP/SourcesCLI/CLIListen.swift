import ArgumentParser
import Foundation
import VedivoxMCPLib

/// One queue item as the app sends it; the same keys go to `--json`.
struct ListenQueueRow: Codable, Equatable {
    let id: String
    let meetingId: String
    let meetingTitle: String
    let speakerId: String
    let speakerLabel: String
    let seconds: Double
    let reason: String
    let bestSimilarity: Double
    let fragment: ListenFragmentRow?
    let line: String?
    let candidates: [ListenCandidateRow]
    let skipped: Bool
    /// Absent from an app older than recurring voices.
    let members: [ListenMemberRow]?

    enum CodingKeys: String, CodingKey {
        case id, seconds, reason, fragment, line, candidates, skipped, members
        case meetingId = "meeting_id", meetingTitle = "meeting_title", speakerId = "speaker_id"
        case speakerLabel = "speaker_label", bestSimilarity = "best_similarity"
    }
}

struct ListenFragmentRow: Codable, Equatable {
    let from: Double
    let to: Double
    let track: String
}

struct ListenMemberRow: Codable, Equatable {
    let meetingId: String
    let speakerId: String

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id", speakerId = "speaker_id"
    }
}

struct ListenCandidateRow: Codable, Equatable {
    let speakerId: String
    let name: String
    let similarity: Double

    enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id", name, similarity
    }
}

struct PinRow: Codable, Equatable {
    let meetingId: String
    let speakerId: String
    let name: String
    let seconds: Double
    let intervals: Int

    enum CodingKeys: String, CodingKey {
        case name, seconds, intervals
        case meetingId = "meeting_id", speakerId = "speaker_id"
    }
}

/// The listen queue from the command line (listen-queue § 8). The queue and
/// every decision are computed by the app (`ListenCommands`), so the CLI and
/// the Listen section cannot disagree; here — parsing, prefixes and printing.
enum CLIListenCore {

    static func queue(meeting: String?, limit: Int?, skipped: Bool, json: Bool, db: DatabaseReader) throws -> String {
        var params: [String: String] = [:]
        if let meeting { params["meeting_id"] = try resolveMeeting(idPrefix: meeting, db: db).id }
        if let limit {
            guard limit >= 0 else { throw CLIFailure(code: 64, message: "--limit must not be negative") }
            params["limit"] = String(limit)
        }
        if skipped { params["skipped"] = "1" }
        let response = try CLIRuntime.sendCommand(AppCommandRequest(command: AppCommandName.listListenQueue, params: params))
        if let failure = cliFailure(from: response) { throw failure }
        let rows = try JSONDecoder().decode([ListenQueueRow].self, from: Data((response.data?["items"] ?? "[]").utf8))
        if json { return try cliJSON(rows) }
        guard !rows.isEmpty else { return skipped ? "no skipped voices" : "nothing to listen to" }
        return rows.map(render).joined(separator: "\n")
    }

    static func render(_ row: ListenQueueRow) -> String {
        let members = row.members ?? [ListenMemberRow(meetingId: row.meetingId, speakerId: row.speakerId)]
        let item = members.map { "\($0.meetingId.prefix(8)):\($0.speakerId.prefix(8))" }.joined(separator: "+")
        let stats = "\(minutes(row.seconds)) · best \(String(format: "%.2f", row.bestSimilarity))"
        // A recurring voice's id runs to hundreds of characters: the heading first, the id below it.
        var lines = row.reason == "recurring"
            ? ["unnamed voice in \(Set(members.map(\.meetingId)).count) meetings · \(stats)", "    item \(item)"]
            : ["\(item)  \(row.meetingTitle) · \(row.speakerLabel) · \(stats)"]
        if let fragment = row.fragment {
            lines.append("    ▶ \(formatTimestamp(fragment.from))–\(formatTimestamp(fragment.to)) \(fragment.track)  «\(row.line ?? "")»")
        }
        lines.append("    " + row.candidates.enumerated().map {
            "\($0.offset + 1) \($0.element.name) \(String(format: "%.2f", $0.element.similarity))"
        }.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }

    private static func minutes(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }

    /// `meetingPrefix:speakerPrefix` → full ids. The speaker resolves among the
    /// meeting's speakers: a record a reprocess replaced is «not found» (2).
    static func resolveItem(_ item: String, db: DatabaseReader) throws -> (meetingId: String, speakerId: String) {
        let parts = item.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw CLIFailure(code: 64, message: "item must be meetingPrefix:speakerPrefix, got \(item)")
        }
        let meeting = try resolveMeeting(idPrefix: parts[0], db: db)
        let matches = try db.listSpeakers(meetingId: meeting.id).map(\.speaker)
            .filter { $0.id.uppercased().hasPrefix(parts[1].uppercased()) }
        switch matches.count {
        case 1:
            return (meeting.id, matches[0].id)
        case 0:
            throw CLIFailure.notFound("no voice \(item): the meeting has no speaker with id starting with \(parts[1])")
        default:
            throw CLIFailure.refusal("speaker prefix \(parts[1]) is ambiguous in meeting \(meeting.id.prefix(8)): "
                + matches.map { "\($0.id) \($0.nameEn)" }.joined(separator: ", "))
        }
    }

    static func assign(item: String, speakerId: String?, newName: String?, db: DatabaseReader) throws -> String {
        // Argument shape before lookups: a bad call reads as a bad call (64).
        var params: [String: String]
        switch (speakerId, newName) {
        case (let id?, nil): params = ["target_speaker_id": id]
        case (nil, let name?):
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CLIFailure(code: 64, message: "--new needs a name")
            }
            params = ["name": name]
        default: throw CLIFailure(code: 64, message: "pass exactly one of --speaker and --new")
        }
        params.merge(try voiceParams(item, db: db)) { $1 }
        return try CLIActionCore.send(AppCommandRequest(command: AppCommandName.assignVoice, params: params))
    }

    static func skip(item: String, db: DatabaseReader) throws -> String {
        try CLIActionCore.send(AppCommandRequest(command: AppCommandName.skipVoice, params: try voiceParams(item, db: db)))
    }

    /// A mixed voice split line by line between known people (`vedivox queue split`).
    static func split(item: String, speakerIds: [String], margin: Double?, db: DatabaseReader) throws -> String {
        guard Set(speakerIds).count >= 2 else { throw CLIFailure(code: 64, message: "pass --speaker at least twice") }
        guard margin.map({ $0 >= 0 }) ?? true else { throw CLIFailure(code: 64, message: "--margin must not be negative") }
        var params = try voiceParams(item, db: db)
        params["candidates"] = speakerIds.joined(separator: ",")
        if let margin { params["margin"] = String(margin) }
        return try CLIActionCore.send(AppCommandRequest(command: AppCommandName.splitVoice, params: params))
    }

    /// One `meetingPrefix:speakerPrefix`, or a recurring voice's `…+…+…` — each part resolved.
    private static func voiceParams(_ item: String, db: DatabaseReader) throws -> [String: String] {
        let voices = try item.split(separator: "+", omittingEmptySubsequences: false).map { try resolveItem(String($0), db: db) }
        guard voices.count > 1 else { return ["meeting_id": voices[0].meetingId, "speaker_id": voices[0].speakerId] }
        return ["members": voices.map { "\($0.meetingId):\($0.speakerId)" }.joined(separator: "+")]
    }

    static func assignRange(
        meeting: String, from: Double, to: Double, track: String?, speakerId: String, db: DatabaseReader
    ) throws -> String {
        guard to > from else { throw CLIFailure(code: 64, message: "--to must be greater than --from") }
        var params = [
            "meeting_id": try resolveMeeting(idPrefix: meeting, db: db).id,
            "from": String(from), "to": String(to), "speaker_id": speakerId,
        ]
        if let track { params["track"] = track }
        return try CLIActionCore.send(AppCommandRequest(command: AppCommandName.assignRange, params: params))
    }

    /// Without `--yes` the app only counts, and the listing comes back as a
    /// refusal (code 1) — nothing is written.
    static func pinSpeakers(meetings: [String], confirmed: Bool, json: Bool, db: DatabaseReader) throws -> String {
        guard !meetings.isEmpty else { throw CLIFailure(code: 64, message: "no meeting id given") }
        var seen = Set<String>()
        let ids = try meetings.map { try resolveMeeting(idPrefix: $0, db: db).id }.filter { seen.insert($0).inserted }
        var params = ["meeting_ids": ids.joined(separator: ",")]
        if !confirmed { params["dry_run"] = "1" }
        let response = try CLIRuntime.sendCommand(AppCommandRequest(command: AppCommandName.pinSpeakers, params: params))
        if let failure = cliFailure(from: response) { throw failure }
        let rows = try JSONDecoder().decode([PinRow].self, from: Data((response.data?["pins"] ?? "[]").utf8))
        let listing = rows.map {
            "\($0.meetingId.prefix(8))  \($0.name) — \(minutes($0.seconds)) in \($0.intervals) interval(s)"
        }
        guard confirmed else {
            throw CLIFailure.refusal(
                "pass --yes to pin these speakers' current lines as verdicts:\n"
                    + listing.map { "  " + $0 }.joined(separator: "\n")
            )
        }
        if json { return try cliJSON(rows) }
        return listing.map { "pinned " + $0 }.joined(separator: "\n")
    }
}

// MARK: - ArgumentParser shells

struct Queue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "queue",
        abstract: "Voices to check by ear: list (default), assign or skip (run through the app).",
        subcommands: [ListQueue.self, AssignVoice.self, SkipVoice.self, SplitVoice.self],
        defaultSubcommand: ListQueue.self
    )

    struct ListQueue: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Unnamed voices that sound like a known person or recur across meetings, most speech first."
        )

        @Option(help: "Only this meeting (id or prefix).") var meeting: String?
        @Option(help: "Max items.") var limit: Int?
        @Flag(help: "Show the skipped voices instead.") var skipped = false
        @Flag(help: "Machine output: one JSON array.") var json = false

        func run() throws {
            try executeCore { db in
                try CLIListenCore.queue(meeting: meeting, limit: limit, skipped: skipped, json: json, db: db)
            }
        }
    }

    struct AssignVoice: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "assign", abstract: "Give every line of the voice to a speaker; the verdict survives reprocess."
        )

        @Argument(help: "Item: meetingPrefix:speakerPrefix, or a recurring voice's parts joined by + (see `vedivox queue`).")
        var item: String
        @Option(help: "Existing speaker id.") var speaker: String?
        @Option(name: .customLong("new"), help: "A new person's name (an existing name lands on that record).")
        var newName: String?

        func run() throws {
            try executeCore { db in try CLIListenCore.assign(item: item, speakerId: speaker, newName: newName, db: db) }
        }
    }

    struct SkipVoice: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "skip", abstract: "Listened, no name: the voice leaves the queue, also after reprocess."
        )

        @Argument(help: "Item: meetingPrefix:speakerPrefix, or a recurring voice's parts joined by + (see `vedivox queue`).")
        var item: String

        func run() throws {
            try executeCore { db in try CLIListenCore.skip(item: item, db: db) }
        }
    }

    struct SplitVoice: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "split",
            abstract: "A voice that is several people: each line goes to the speaker it sounds closest to; unclear lines stay."
        )

        @Argument(help: "Item: meetingPrefix:speakerPrefix, or a recurring voice's parts joined by + (see `vedivox queue`).")
        var item: String
        @Option(name: .customLong("speaker"), help: "A speaker id to split between (repeat, at least two).")
        var speakers: [String] = []
        @Option(help: "How far a line's best speaker must lead the next (default 0.05).") var margin: Double?

        func run() throws {
            try executeCore { db in try CLIListenCore.split(item: item, speakerIds: speakers, margin: margin, db: db) }
        }
    }
}

struct PinSpeakers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin-speakers",
        abstract: "Pin the current lines of confirmed speakers as verdicts, so a reprocess keeps them."
    )

    @Argument(help: "Meeting ids or unambiguous prefixes.") var meetingIds: [String]
    @Flag(help: "Actually pin; without it the command only lists who and how much.") var yes = false
    @Flag(help: "Machine output: one JSON array.") var json = false

    func run() throws {
        try executeCore { db in try CLIListenCore.pinSpeakers(meetings: meetingIds, confirmed: yes, json: json, db: db) }
    }
}
