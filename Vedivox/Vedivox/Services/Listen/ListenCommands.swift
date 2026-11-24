import Foundation

/// The listen-queue app commands (design § 8): `vedivox queue`, `vedivox queue
/// assign|skip`, the range form of `vedivox segment set` and `vedivox meeting
/// pin-speakers`. Parameters are parsed and executed here, in the headless
/// core, so the same code the app runs is what the tests run.
enum ListenCommands {
    static let names: Set<String> = [
        AppCommandName.listListenQueue, AppCommandName.assignVoice, AppCommandName.skipVoice, AppCommandName.splitVoice,
        AppCommandName.assignRange, AppCommandName.pinSpeakers,
    ]

    struct QueueFragment: Codable, Equatable {
        /// A recurring voice's longest fragment may be from another of its meetings than `meeting_id` of the row.
        let meetingId: String
        let from: Double
        let to: Double
        let track: String
    }

    struct QueueMember: Codable, Equatable {
        let meetingId: String
        let speakerId: String
    }

    struct QueueCandidate: Codable, Equatable {
        let speakerId: String
        let name: String
        let similarity: Double
    }

    /// A queue item on the wire (snake_case keys, stable contract).
    struct QueueRow: Codable, Equatable {
        let id: String
        let meetingId: String
        let meetingTitle: String
        let speakerId: String
        let speakerLabel: String
        let seconds: Double
        let reason: String
        let bestSimilarity: Double
        let fragment: QueueFragment?
        let line: String?
        let candidates: [QueueCandidate]
        let skipped: Bool
        /// Every record of the voice: one, or one per meeting of a recurring voice.
        let members: [QueueMember]
    }

    struct PinRow: Codable, Equatable {
        let meetingId: String
        let speakerId: String
        let name: String
        let seconds: Double
        let intervals: Int
    }

    static func handle(_ request: AppCommandRequest, db: DatabaseManager = .shared) async -> AppCommandResponse {
        let p = request.params
        do {
            switch request.command {
            case AppCommandName.listListenQueue:
                var items = try await ListenQueueBuilder(db: db)
                    .build(meetingId: nonEmpty(p["meeting_id"]), skipped: p["skipped"] == "1")
                if let limit = p["limit"].flatMap(Int.init), limit >= 0 { items = Array(items.prefix(limit)) }
                return .success("\(items.count) voice(s)", data: ["items": try encode(items.map(row))])

            case AppCommandName.assignVoice:
                guard let members = members(p) else {
                    return .failure("\(request.command) needs meeting_id and speaker_id, or members", reason: .invalidParameters)
                }
                let target: SpeakerVerdicts.Target
                switch (nonEmpty(p["target_speaker_id"]), nonEmpty(p["name"])) {
                case (let id?, nil): target = .existing(speakerId: id)
                case (nil, let name?): target = .new(name: name)
                default:
                    return .failure("pass exactly one of target_speaker_id and name", reason: .invalidParameters)
                }
                let (meetings, ids) = try await voice(members, db: db)
                guard !ids.isEmpty else { return voiceGone(members) }
                let outcomes = try await SpeakerVerdicts(db: db).assign(meetingIds: meetings, segmentIds: ids, to: target)
                guard let last = outcomes.last else { return voiceGone(members) }
                return .success(outcomes.map(\.summary).joined(separator: "\n"), data: ["speaker_id": last.speaker.id])

            case AppCommandName.skipVoice:
                guard let members = members(p) else {
                    return .failure("\(request.command) needs meeting_id and speaker_id, or members", reason: .invalidParameters)
                }
                let (meetings, ids) = try await voice(members, db: db)
                guard !ids.isEmpty else { return voiceGone(members) }
                let intervals = try await SpeakerVerdicts(db: db).skip(meetingIds: meetings, segmentIds: ids)
                return .success("Skipped \(ids.count) segment(s) in \(intervals) interval(s)")

            case AppCommandName.splitVoice:
                guard let members = members(p) else {
                    return .failure("\(request.command) needs meeting_id and speaker_id, or members", reason: .invalidParameters)
                }
                let candidates = (p["candidates"] ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard candidates.count >= 2 else {
                    return .failure("\(request.command) needs at least two candidates", reason: .invalidParameters)
                }
                var margin = SpeakerVerdicts.splitMargin
                if let raw = nonEmpty(p["margin"]) {
                    guard let parsed = Float(raw), parsed >= 0 else {
                        return .failure("margin must be a non-negative number", reason: .invalidParameters)
                    }
                    margin = parsed
                }
                for id in candidates where try await SpeakerRepository(db: db).find(id)?.isConfirmed != true {
                    return .failure("Speaker \(id) not found or not confirmed", reason: .notFound)
                }
                let (meetings, ids) = try await voice(members, db: db)
                guard !ids.isEmpty else { return voiceGone(members) }
                let outcome = try await SpeakerVerdicts(db: db)
                    .split(meetingIds: meetings, segmentIds: ids, between: candidates, margin: margin)
                return .success(outcome.summary)

            case AppCommandName.assignRange:
                guard let meetingId = nonEmpty(p["meeting_id"]), let speakerId = nonEmpty(p["speaker_id"]),
                      let from = p["from"].flatMap(Double.init), let to = p["to"].flatMap(Double.init)
                else {
                    return .failure("\(request.command) needs meeting_id, speaker_id and numeric from, to",
                                    reason: .invalidParameters)
                }
                guard to > from else { return .failure("to must be greater than from", reason: .invalidParameters) }
                var track: SegmentSource?
                if let raw = nonEmpty(p["track"]) {
                    guard let parsed = SegmentSource(rawValue: raw) else {
                        return .failure("unknown track \(raw)", reason: .invalidParameters)
                    }
                    track = parsed
                }
                guard try await MeetingRepository(db: db).find(meetingId) != nil else {
                    return .failure("Meeting \(meetingId) not found", reason: .notFound)
                }
                let outcome = try await SpeakerVerdicts(db: db)
                    .assignRange(meetingId: meetingId, from: from, to: to, track: track, speakerId: speakerId)
                return .success(outcome.summary)

            case AppCommandName.pinSpeakers:
                let ids = (p["meeting_ids"] ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !ids.isEmpty else {
                    return .failure("\(request.command) is missing meeting_ids", reason: .invalidParameters)
                }
                let repo = MeetingRepository(db: db)
                for id in ids where try await repo.find(id) == nil {
                    return .failure("Meeting \(id) not found", reason: .notFound)
                }
                let dryRun = p["dry_run"] == "1"
                var rows: [PinRow] = []
                for id in ids {
                    rows += try await SpeakerVerdicts(db: db).pin(meetingId: id, dryRun: dryRun).map {
                        PinRow(meetingId: id, speakerId: $0.speakerId, name: $0.name, seconds: $0.seconds, intervals: $0.intervals)
                    }
                }
                let verb = dryRun ? "would pin" : "pinned"
                return .success("\(verb) \(rows.count) speaker(s) in \(ids.count) meeting(s)", data: ["pins": try encode(rows)])

            default:
                return .failure("Unknown command: \(request.command)", reason: .unknownCommand)
            }
        } catch SpeakerVerdicts.VerdictError.speakerNotFound(let id) {
            return .failure("Speaker \(id) not found", reason: .notFound)
        } catch SpeakerVerdicts.VerdictError.noSegments {
            return .failure("No segments to assign", reason: .notFound)
        } catch {
            Log.error("\(request.command) failed: \(error)")
            return .failure("\(request.command) failed: \(error.localizedDescription)", reason: .failed)
        }
    }

    static func row(_ item: ListenQueueItem) -> QueueRow {
        let (reason, bestSim): (String, Float) = switch item.reason {
        case .almostKnown(let sim): ("almost_known", sim)
        case .recurring: ("recurring", item.candidates.first?.similarity ?? 0)
        }
        return QueueRow(
            id: item.id,
            meetingId: item.members[0].meetingId,
            meetingTitle: item.meetingTitle,
            speakerId: item.members[0].speakerId,
            speakerLabel: item.speakerLabel,
            seconds: item.seconds,
            reason: reason,
            bestSimilarity: rounded(bestSim),
            fragment: item.anchor.map { .init(meetingId: $0.meetingId, from: $0.start, to: $0.end, track: $0.track.rawValue) },
            line: item.anchor?.text,
            candidates: item.candidates.map { .init(speakerId: $0.speakerId, name: $0.name, similarity: rounded($0.similarity)) },
            skipped: item.isSkipped,
            members: item.members.map { .init(meetingId: $0.meetingId, speakerId: $0.speakerId) }
        )
    }

    /// The item's records: `members` as `meetingId:speakerId+…` (a recurring
    /// voice), else the one `meeting_id` and `speaker_id`.
    private static func members(_ p: [String: String]) -> [ListenQueueItem.Member]? {
        if let raw = nonEmpty(p["members"]) {
            let pairs = raw.split(separator: "+").map { $0.split(separator: ":", omittingEmptySubsequences: false) }
            guard pairs.allSatisfy({ $0.count == 2 && !$0[0].isEmpty && !$0[1].isEmpty }) else { return nil }
            return pairs.map { .init(meetingId: String($0[0]), speakerId: String($0[1])) }
        }
        guard let meetingId = nonEmpty(p["meeting_id"]), let speakerId = nonEmpty(p["speaker_id"]) else { return nil }
        return [.init(meetingId: meetingId, speakerId: speakerId)]
    }

    /// The lines of an item: each record's non-excluded lines in its meeting,
    /// and the meetings that still have any. Empty when reprocess replaced them all.
    private static func voice(_ members: [ListenQueueItem.Member], db: DatabaseManager) async throws
        -> (meetings: [String], ids: [Int64])
    {
        var meetings: [String] = []
        var ids: [Int64] = []
        for member in members {
            let own = try await MeetingRepository(db: db).segments(for: member.meetingId)
                .filter { $0.speakerId == member.speakerId && !$0.isExcluded }
                .compactMap(\.id)
            guard !own.isEmpty else { continue }
            if !meetings.contains(member.meetingId) { meetings.append(member.meetingId) }
            ids += own
        }
        return (meetings, ids)
    }

    private static func voiceGone(_ members: [ListenQueueItem.Member]) -> AppCommandResponse {
        let what = members.map { "\($0.meetingId):\($0.speakerId)" }.joined(separator: "+")
        return .failure("No voice \(what) — reprocessed or already decided", reason: .notFound)
    }

    private static func rounded(_ value: Float) -> Double { (Double(value) * 1000).rounded() / 1000 }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(bytes: try encoder.encode(value), encoding: .utf8) ?? "null"
    }
}
