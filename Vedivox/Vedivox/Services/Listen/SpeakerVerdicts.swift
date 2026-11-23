import Foundation
import GRDB

/// The one «I know who this is» action (listen-queue § 5): the listen queue,
/// the transcript and `vedivox segment set` all move lines through here, so every
/// path writes a verdict that survives reprocess and recalculates the voices
/// on both sides.
struct SpeakerVerdicts {
    enum Target: Equatable {
        case existing(speakerId: String)
        /// A typed name: lands on an existing record with that name, if any.
        case new(name: String)
    }

    enum VerdictError: Error, Equatable {
        /// None of the segment ids belongs to the meeting.
        case noSegments
        case speakerNotFound(String)
    }

    struct AssignOutcome {
        let speaker: Speaker
        let segments: Int
        let seconds: Double
        /// Verdict marks written — one per contiguous run of moved lines.
        let intervals: Int
        let target: [EmbeddingSpace: SpeakerRepository.RecalcOutcome]
        /// Donors that still exist after the move, by id.
        let donors: [String: [EmbeddingSpace: SpeakerRepository.RecalcOutcome]]

        /// "12 segment(s) (431.0s) → Rosa; canonical v1: saved, v2: saved" for responses.
        var summary: String {
            let moved = String(format: "%d segment(s) (%.1fs)", segments, seconds)
            var line = "\(moved) → \(speaker.displayName); \(SpeakerRepository.RecalcOutcome.summary(target))"
            for donor in donors.keys.sorted() {
                line += "; donor \(donor): \(SpeakerRepository.RecalcOutcome.summary(donors[donor] ?? [:]))"
            }
            return line
        }
    }

    private let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    /// Moves the segments to the target, confirms it, writes `speaker` verdicts
    /// over their runs, keeps the meeting's links true (an anonymous row left
    /// without lines goes) and recalculates target and donors.
    func assign(
        meetingId: String,
        segmentIds: [Int64],
        to target: Target,
        source: MarkSource = .manual,
        verdictIntervals: [(track: SegmentSource, start: Double, end: Double)]? = nil
    ) async throws -> AssignOutcome {
        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)
        let segments = try await chosen(meetingId: meetingId, segmentIds: segmentIds)

        let speaker: Speaker
        switch target {
        case .existing(let id):
            guard let found = try await speakerRepo.find(id) else { throw VerdictError.speakerNotFound(id) }
            speaker = found
        case .new(let name):
            speaker = try await speakerRepo.findOrCreateSpeaker(name: name)
        }
        try await speakerRepo.confirmSpeaker(speaker.id)

        try await meetingRepo.updateSegmentsSpeaker(
            ids: segments.compactMap(\.id), meetingId: meetingId,
            speakerId: speaker.id, speakerLabel: speaker.displayName
        )
        let intervals = try await write(
            .speaker, speakerId: speaker.id,
            intervals: verdictIntervals ?? ForeignVoicePolicy.coalescedIntervals(of: segments),
            meetingId: meetingId, source: source
        )
        try await speakerRepo.cleanupOrphanedSpeakers()

        let targetOutcome = try await speakerRepo.recalculateEmbedding(speakerId: speaker.id)
        var donors: [String: [EmbeddingSpace: SpeakerRepository.RecalcOutcome]] = [:]
        for donor in Set(segments.compactMap(\.speakerId)).subtracting([speaker.id]).sorted() {
            guard try await speakerRepo.find(donor) != nil else { continue }
            donors[donor] = try await speakerRepo.recalculateEmbedding(speakerId: donor)
        }

        let outcome = AssignOutcome(
            speaker: speaker,
            segments: segments.count,
            seconds: segments.reduce(0) { $0 + $1.endTime - $1.startTime },
            intervals: intervals,
            target: targetOutcome,
            donors: donors
        )
        Log.info("Verdict in \(meetingId): \(outcome.summary)")
        return outcome
    }

    /// One decision over a voice heard in several meetings (a recurring queue
    /// item): each meeting's share of `segmentIds` goes to the same person; a
    /// typed name creates them once. Outcomes in meeting order.
    func assign(meetingIds: [String], segmentIds: [Int64], to target: Target) async throws -> [AssignOutcome] {
        var target = target
        var outcomes: [AssignOutcome] = []
        for meetingId in meetingIds {
            let outcome = try await assign(meetingId: meetingId, segmentIds: segmentIds, to: target)
            target = .existing(speakerId: outcome.speaker.id)
            outcomes.append(outcome)
        }
        return outcomes
    }

    /// A line goes to the closest candidate only this far ahead of the runner-up.
    static let splitMargin: Float = 0.05

    struct SplitOutcome {
        /// One per (meeting, person) that got lines.
        let assigned: [AssignOutcome]
        /// Lines no candidate won clearly; they stay where they were.
        let unclear: Int

        var summary: String {
            (assigned.map(\.summary) + ["\(unclear) unclear segment(s) left"]).joined(separator: "\n")
        }
    }

    /// One anonymous voice that is really two or three people: each line goes
    /// to the candidate its own embedding is closest to, when it leads the
    /// runner-up by `margin`, through `assign` — so verdicts and recalcs are
    /// the usual ones. Lines without a clear winner stay.
    func split(
        meetingIds: [String], segmentIds: [Int64], between candidates: [String], margin: Float = splitMargin
    ) async throws -> SplitOutcome {
        let wanted = Set(segmentIds)
        var assigned: [AssignOutcome] = []
        var unclear = 0
        for meetingId in meetingIds {
            guard let meeting = try await MeetingRepository(db: db).find(meetingId) else { continue }
            let space: EmbeddingSpace = meeting.diarizer == "offline" ? .v2 : .v1
            let canonicals = try await SpeakerRepository(db: db).confirmedSpeakersWithEmbeddings(space: space)
                .filter { candidates.contains($0.id) }
                .map { (id: $0.id, canonical: $0.canonical) }
            var lines: [String: [Int64]] = [:]
            for segment in try await MeetingRepository(db: db).segments(for: meetingId) {
                guard let id = segment.id, wanted.contains(id) else { continue }
                guard let data = segment.embedding,
                      let winner = Self.closest(Speaker.decodeEmbedding(data), among: canonicals, margin: margin)
                else {
                    unclear += 1
                    continue
                }
                lines[winner, default: []].append(id)
            }
            for (speakerId, ids) in lines.sorted(by: { $0.key < $1.key }) {
                assigned.append(try await assign(meetingId: meetingId, segmentIds: ids, to: .existing(speakerId: speakerId)))
            }
        }
        return SplitOutcome(assigned: assigned, unclear: unclear)
    }

    /// The candidate `voice` is closest to, when it leads the runner-up by `margin`.
    static func closest(_ voice: [Float], among canonicals: [(id: String, canonical: [Float])], margin: Float) -> String? {
        let ranked = canonicals.filter { $0.canonical.count == voice.count && !voice.isEmpty }
            .map { (id: $0.id, sim: cosineSimilarity(voice, $0.canonical)) }
            .sorted { $0.sim > $1.sim }
        guard let best = ranked.first else { return nil }
        guard ranked.count > 1 else { return best.id }
        return best.sim - ranked[1].sim >= margin ? best.id : nil
    }

    /// `skip` over each meeting of a recurring voice. Returns the intervals written.
    func skip(meetingIds: [String], segmentIds: [Int64]) async throws -> Int {
        var intervals = 0
        for meetingId in meetingIds {
            intervals += try await skip(meetingId: meetingId, segmentIds: segmentIds)
        }
        return intervals
    }

    /// One segment by id, its meeting looked up (`vedivox segment set <segment-id>`).
    func assign(segmentId: Int64, to speakerId: String) async throws -> AssignOutcome {
        guard let meetingId = try await db.reader.read({ db in
            try String.fetchOne(db, sql: "SELECT meetingId FROM transcript_segments WHERE id = ?", arguments: [segmentId])
        }) else { throw VerdictError.noSegments }
        return try await assign(meetingId: meetingId, segmentIds: [segmentId], to: .existing(speakerId: speakerId))
    }

    /// «Listened, no name»: `skipped` marks over the segments' runs; nothing
    /// moves. Returns how many intervals were written.
    @discardableResult
    func skip(meetingId: String, segmentIds: [Int64]) async throws -> Int {
        let segments = try await chosen(meetingId: meetingId, segmentIds: segmentIds)
        let intervals = try await write(
            .skipped, speakerId: nil, intervals: ForeignVoicePolicy.coalescedIntervals(of: segments),
            meetingId: meetingId, source: .manual
        )
        Log.info("Skipped in \(meetingId): \(segments.count) segment(s), \(intervals) interval(s)")
        return intervals
    }

    private func chosen(meetingId: String, segmentIds: [Int64]) async throws -> [TranscriptSegment] {
        let wanted = Set(segmentIds)
        let segments = try await MeetingRepository(db: db).segments(for: meetingId)
            .filter { $0.id.map(wanted.contains) ?? false }
        guard !segments.isEmpty else { throw VerdictError.noSegments }
        return segments
    }

    /// The lines of `track` (every track when nil) that `[from, to]` covers for
    /// at least half their length go to the speaker; the verdict lies exactly on
    /// `[from, to]` of each track that had such lines (`vedivox segment set --from --to`).
    func assignRange(
        meetingId: String, from: Double, to: Double, track: SegmentSource?, speakerId: String
    ) async throws -> AssignOutcome {
        let covered = try await MeetingRepository(db: db).segments(for: meetingId).filter { segment in
            guard track == nil || segment.source == track else { return false }
            let length = segment.endTime - segment.startTime
            let overlap = min(segment.endTime, to) - max(segment.startTime, from)
            return length > 0 && overlap >= VerdictProjection.coverageThreshold * length
        }
        let tracks = Set(covered.map(\.source)).sorted { $0.rawValue < $1.rawValue }
        return try await assign(
            meetingId: meetingId, segmentIds: covered.compactMap(\.id), to: .existing(speakerId: speakerId),
            verdictIntervals: tracks.map { (track: $0, start: from, end: to) }
        )
    }

    struct Pin: Equatable {
        let speakerId: String
        let name: String
        let seconds: Double
        let intervals: Int
    }

    /// Pins the current attribution of every confirmed and `isMe` speaker in
    /// the meeting as `speaker`/`pin` verdicts, so a reprocess hands their
    /// lines back (design § 8). `dryRun` only reports who and how much.
    func pin(meetingId: String, dryRun: Bool) async throws -> [Pin] {
        let segments = try await MeetingRepository(db: db).segments(for: meetingId)
        let named = try await db.reader.read { db in
            try Speaker.fetchAll(db, sql: """
                SELECT * FROM speakers WHERE (isConfirmed = 1 OR isMe = 1)
                AND id IN (SELECT speakerId FROM transcript_segments WHERE meetingId = ?)
                """, arguments: [meetingId])
        }.sorted { $0.displayName < $1.displayName }

        var pins: [Pin] = []
        for speaker in named {
            let own = segments.filter { $0.speakerId == speaker.id }
            let runs = ForeignVoicePolicy.coalescedIntervals(of: own)
            if !dryRun {
                try await write(.speaker, speakerId: speaker.id, intervals: runs, meetingId: meetingId, source: .pin)
            }
            pins.append(Pin(
                speakerId: speaker.id, name: speaker.displayName,
                seconds: own.reduce(0) { $0 + $1.endTime - $1.startTime }, intervals: runs.count
            ))
        }
        if !dryRun {
            Log.info("Pinned \(pins.count) speaker(s) in \(meetingId): \(pins.map { "\($0.name) \(Int($0.seconds))s/\($0.intervals)" }.joined(separator: ", "))")
        }
        return pins
    }

    /// One `createdAt` for the batch, so a decision counts once in the
    /// manual-work metric (design § 9).
    @discardableResult
    private func write(
        _ kind: MarkKind, speakerId: String?, intervals: [(track: SegmentSource, start: Double, end: Double)],
        meetingId: String, source: MarkSource
    ) async throws -> Int {
        let markRepo = MarkRepository(db: db)
        let now = Date()
        for run in intervals {
            try await markRepo.add(MeetingMark(
                meetingId: meetingId, startTime: run.start, endTime: run.end, track: run.track,
                kind: kind, source: source, createdAt: now, speakerId: speakerId
            ))
        }
        return intervals.count
    }
}
