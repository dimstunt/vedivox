import Foundation

/// The listen-queue app commands (design § 8): `vedivox queue`, `vedivox queue
/// assign|skip`, the range form of `vedivox segment set` and `vedivox meeting
/// pin-speakers`. Parameters are parsed and executed here, in the headless
/// core, so the same code the app runs is what the tests run.
enum ListenCommands {
    static let names: Set<String> = [
        AppCommandName.listListenQueue, AppCommandName.assignVoice, AppCommandName.skipVoice,
        AppCommandName.assignRange, AppCommandName.pinSpeakers,
    ]

    struct QueueFragment: Codable, Equatable {
        let from: Double
        let to: Double
        let track: String
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
                guard let meetingId = nonEmpty(p["meeting_id"]), let speakerId = nonEmpty(p["speaker_id"]) else {
                    return .failure("\(request.command) needs meeting_id and speaker_id", reason: .invalidParameters)
                }
                let target: SpeakerVerdicts.Target
                switch (nonEmpty(p["target_speaker_id"]), nonEmpty(p["name"])) {
                case (let id?, nil): target = .existing(speakerId: id)
                case (nil, let name?): target = .new(name: name)
                default:
                    return .failure("pass exactly one of target_speaker_id and name", reason: .invalidParameters)
                }
                let ids = try await voice(meetingId: meetingId, speakerId: speakerId, db: db)
                guard !ids.isEmpty else { return voiceGone(meetingId, speakerId) }
                let outcome = try await SpeakerVerdicts(db: db).assign(meetingId: meetingId, segmentIds: ids, to: target)
                return .success(outcome.summary, data: ["speaker_id": outcome.speaker.id])

            case AppCommandName.skipVoice:
                guard let meetingId = nonEmpty(p["meeting_id"]), let speakerId = nonEmpty(p["speaker_id"]) else {
                    return .failure("\(request.command) needs meeting_id and speaker_id", reason: .invalidParameters)
                }
                let ids = try await voice(meetingId: meetingId, speakerId: speakerId, db: db)
                guard !ids.isEmpty else { return voiceGone(meetingId, speakerId) }
                let intervals = try await SpeakerVerdicts(db: db).skip(meetingId: meetingId, segmentIds: ids)
                return .success("Skipped \(ids.count) segment(s) in \(intervals) interval(s)")

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
        guard case .almostKnown(let bestSim) = item.reason else { preconditionFailure("one reason in this change") }
        return QueueRow(
            id: item.id,
            meetingId: item.members[0].meetingId,
            meetingTitle: item.meetingTitle,
            speakerId: item.members[0].speakerId,
            speakerLabel: item.speakerLabel,
            seconds: item.seconds,
            reason: "almost_known",
            bestSimilarity: rounded(bestSim),
            fragment: item.anchor.map { .init(from: $0.start, to: $0.end, track: $0.track.rawValue) },
            line: item.anchor?.text,
            candidates: item.candidates.map { .init(speakerId: $0.speakerId, name: $0.name, similarity: rounded($0.similarity)) },
            skipped: item.isSkipped
        )
    }

    /// The lines of an item: the record's non-excluded lines in the meeting.
    /// Empty when a reprocess replaced the record.
    private static func voice(meetingId: String, speakerId: String, db: DatabaseManager) async throws -> [Int64] {
        try await MeetingRepository(db: db).segments(for: meetingId)
            .filter { $0.speakerId == speakerId && !$0.isExcluded }
            .compactMap(\.id)
    }

    private static func voiceGone(_ meetingId: String, _ speakerId: String) -> AppCommandResponse {
        .failure("No voice \(meetingId):\(speakerId) — reprocessed or already decided", reason: .notFound)
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
