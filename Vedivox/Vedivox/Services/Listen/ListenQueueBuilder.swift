import Foundation
import GRDB

/// One voice to check by ear: the lines of an anonymous record in a meeting
/// (listen-queue § 1), or of the anonymous records of one unnamed voice that
/// recurs across meetings — then `members` holds one record per meeting.
struct ListenQueueItem: Identifiable, Equatable, Sendable {
    struct Member: Hashable, Sendable {
        let meetingId: String
        let speakerId: String
    }

    enum Reason: Equatable, Sendable {
        case almostKnown(bestSim: Float)
        /// Like no confirmed person, but the same voice in this many meetings.
        case recurring(meetings: Int)
    }

    /// A stretch to play: a run of the voice's lines on one track.
    struct Fragment: Equatable, Sendable {
        let meetingId: String
        let start: Double
        let end: Double
        let track: SegmentSource
        let text: String
        var length: Double { end - start }
    }

    struct Candidate: Equatable, Sendable {
        let speakerId: String
        let name: String
        let similarity: Float
        /// The candidate's longest line in their most recent other meeting of
        /// the same embedding space — «what they sound like».
        let sample: Fragment?
    }

    let members: [Member]
    let reason: Reason
    /// Non-excluded speech at stake — the sort key.
    let seconds: Double
    let meetingTitle: String
    let meetingStart: Date
    let speakerLabel: String
    /// Longest first.
    let fragments: [Fragment]
    /// Best first, at most `Config.candidates`.
    let candidates: [Candidate]
    let isSkipped: Bool
    /// Every line of the item, for the decision; spans the members' meetings.
    let segmentIds: [Int64]
    /// Titles of the members' meetings: a recurring voice's fragments come from several.
    var meetingTitles: [String: String] = [:]

    var id: String { members.map { "\($0.meetingId):\($0.speakerId)" }.joined(separator: "+") }
    var anchor: Fragment? { fragments.first }
    /// The meetings a decision touches, each once.
    var meetingIds: [String] {
        var seen = Set<String>()
        return members.map(\.meetingId).filter { seen.insert($0).inserted }
    }

    /// The row's name: the meeting and label of one record, or how far a recurring voice reaches.
    var heading: String {
        if case .recurring(let meetings) = reason { return "Unnamed voice in \(meetings) meetings" }
        return "\(meetingTitle) · \(speakerLabel)"
    }
}

/// Computes the listen queue from the database (listen-queue §§ 1–2); nothing
/// is stored but the decisions. Two sources: an anonymous voice of a finished
/// meeting that sounds like a confirmed person, and an anonymous voice like no
/// one that recurs in several meetings (`unnamed-regular-detector`).
struct ListenQueueBuilder {
    struct Config {
        var minSeconds = 60.0
        var minSimilarity: Float = 0.65
        var candidates = 3
        /// A voice at least this much covered by `skipped` marks stays hidden.
        var skippedCoverage = 0.5
        /// Lines of one voice glue into a fragment across a pause this short
        /// when nobody else spoke on the track in between.
        var fragmentGap = 1.0
        /// Voices of different meetings join while their mean similarity is
        /// at least this: the matcher's accept, above 99.5% of different-person
        /// pairs of confirmed per-meeting voices (2026-11-23, raw cosine).
        var groupSimilarity: Float = 0.70
        /// A group becomes an item when it spans this many meetings.
        var groupMeetings = 3
    }

    private let db: DatabaseManager
    private let config: Config

    init(db: DatabaseManager = .shared, config: Config = Config()) {
        self.db = db
        self.config = config
    }

    /// The queue in display order. `skipped: true` lists only the voices a
    /// person skipped (the «Skipped» toggle, `vedivox queue --skipped`).
    func build(meetingId: String? = nil, skipped: Bool = false) async throws -> [ListenQueueItem] {
        var trace = PerfTrace("ListenQueueBuilder.build")
        defer { trace.finish() }
        let voices = try await voices(meetingId: meetingId, skipped: skipped, trace: &trace)

        var items: [ListenQueueItem] = []
        for pick in voices {
            let anchor = pick.voices[0]
            var fragments: [ListenQueueItem.Fragment] = []
            var segmentIds: [Int64] = []
            for voice in pick.voices {
                let lines = try await lines(of: voice.member)
                let own = Self.fragments(of: voice.member.speakerId, in: lines, gap: config.fragmentGap)
                // A recurring voice is heard across meetings: the longest stretch of each.
                fragments += pick.voices.count == 1 ? own : Array(own.prefix(1))
                segmentIds += lines.filter { $0.speakerId != nil }.compactMap(\.id)
            }
            var candidates: [ListenQueueItem.Candidate] = []
            for candidate in pick.ranked {
                candidates.append(.init(
                    speakerId: candidate.id, name: candidate.name, similarity: candidate.sim,
                    sample: try await sample(of: candidate.id, space: anchor.space, besides: anchor.member.meetingId)
                ))
            }
            items.append(ListenQueueItem(
                members: pick.voices.map(\.member),
                reason: pick.reason,
                seconds: pick.voices.reduce(0) { $0 + $1.seconds },
                meetingTitle: anchor.title,
                meetingStart: anchor.meetingStart,
                speakerLabel: anchor.label,
                fragments: fragments.sorted { $0.length != $1.length ? $0.length > $1.length : $0.start < $1.start },
                candidates: candidates,
                isSkipped: pick.isSkipped,
                segmentIds: segmentIds,
                meetingTitles: Dictionary(pick.voices.map { ($0.member.meetingId, $0.title) }) { $1 }
            ))
        }
        trace.checkpoint("items \(items.count)")
        return items.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
    }

    /// How many voices `build` lists — the sidebar badge and «N voices to
    /// check». Stops before the lines, fragments and samples of an item.
    func count(meetingId: String? = nil) async throws -> Int {
        var trace = PerfTrace("ListenQueueBuilder.count")
        defer { trace.finish() }
        return try await voices(meetingId: meetingId, skipped: false, trace: &trace).count
    }

    private typealias Ranked = [(id: String, name: String, sim: Float)]

    /// An anonymous record of a finished meeting with enough speech, before its lines are read.
    private struct Voice {
        let member: ListenQueueItem.Member
        let seconds: Double
        let title: String
        let meetingStart: Date
        let label: String
        let space: EmbeddingSpace
        let vector: [Float]
        let isSkipped: Bool
    }

    /// What becomes one item: its voices, most speech first.
    private struct Pick {
        let voices: [Voice]
        let reason: ListenQueueItem.Reason
        /// Best first; never empty for `.almostKnown`.
        let ranked: Ranked
        /// A recurring voice comes back when a meeting adds an unskipped record.
        var isSkipped: Bool { voices.allSatisfy(\.isSkipped) }
    }

    private func voices(meetingId: String?, skipped: Bool, trace: inout PerfTrace) async throws -> [Pick] {
        // One aggregate over every anonymous voice of a finished meeting, read
        // from idx_segments_voice alone (v27). CROSS JOIN pins the order —
        // anonymous speakers first, then their lines; left to itself the
        // planner walks every line of the table and its 1 KB embedding.
        let rows = try await db.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts.meetingId, ts.speakerId, s.nameEn, m.title, m.startTime AS meetingStart,
                       m.diarizer, SUM(MAX(ts.endTime - ts.startTime, 0)) AS seconds,
                       COUNT(*) AS lines, MAX(ts.id) AS lastId
                FROM speakers s
                CROSS JOIN transcript_segments ts ON ts.speakerId = s.id
                JOIN meetings m ON m.id = ts.meetingId
                WHERE m.status = ? AND s.isConfirmed = 0 AND s.isMe = 0
                  AND ts.isExcluded = 0
                  AND (? IS NULL OR ts.meetingId = ?)
                GROUP BY ts.meetingId, ts.speakerId
                HAVING seconds >= ?
                """,
                arguments: [MeetingStatus.done.rawValue, meetingId, meetingId, config.minSeconds])
        }.filter { Speaker.isAutoLabel($0["nameEn"]) }
        trace.checkpoint("aggregate \(rows.count)")

        var pools: [EmbeddingSpace: [(id: String, name: String, canonical: [Float])]] = [:]
        for space in EmbeddingSpace.allCases {
            pools[space] = try await SpeakerRepository(db: db).confirmedSpeakersWithEmbeddings(space: space)
        }
        // «Skipped» marks are rare: one read finds the meetings that have any,
        // and only their voices pay for reading lines here.
        let skips = Dictionary(grouping: try await db.reader.read { db in
            try MeetingMark.filter(MeetingMark.Columns.kind == MarkKind.skipped.rawValue).fetchAll(db)
        }, by: \.meetingId)

        func rank(_ vector: [Float], _ space: EmbeddingSpace) -> Ranked {
            Array((pools[space] ?? [])
                .map { (id: $0.id, name: $0.name, sim: cosineSimilarity(vector, $0.canonical)) }
                .sorted { $0.sim > $1.sim }
                .prefix(config.candidates))
        }

        var picks: [Pick] = []
        var unlike: [Voice] = []
        for row in rows {
            let member = ListenQueueItem.Member(meetingId: row["meetingId"], speakerId: row["speakerId"])
            let diarizer: String? = row["diarizer"]
            let space: EmbeddingSpace = diarizer == "offline" ? .v2 : .v1
            guard let vector = try await meetingVoice(member), vector.count == 256 else { continue }

            var isSkipped = false
            if let marks = skips[member.meetingId] {
                let own = try await lines(of: member).filter { $0.speakerId != nil }
                isSkipped = Self.skippedShare(of: own, verdicts: marks) >= config.skippedCoverage
            }
            let voice = Voice(
                member: member, seconds: row["seconds"], title: row["title"], meetingStart: row["meetingStart"],
                label: row["nameEn"], space: space, vector: vector, isSkipped: isSkipped
            )
            let ranked = rank(vector, space)
            if let best = ranked.first, best.sim >= config.minSimilarity {
                picks.append(Pick(voices: [voice], reason: .almostKnown(bestSim: best.sim), ranked: ranked))
            } else if space == .v2 {
                // shortcut: only v2 voices group, the threshold is calibrated there; v1 meetings are legacy.
                unlike.append(voice)
            }
        }

        for group in Self.groups(unlike.map(\.vector), threshold: config.groupSimilarity) {
            let voices = group.map { unlike[$0] }.sorted { $0.seconds > $1.seconds }
            let meetings = Set(voices.map(\.member.meetingId)).count
            guard meetings >= config.groupMeetings else { continue }
            let centroid = SpeakerRepository.naiveMean(voices.map(\.vector))
            picks.append(Pick(voices: voices, reason: .recurring(meetings: meetings), ranked: rank(centroid, .v2)))
        }
        picks.removeAll { $0.isSkipped != skipped }
        trace.checkpoint("voices \(picks.count)")
        return picks
    }

    /// Average linkage over cosine similarity: the two closest clusters merge
    /// while the mean similarity of their pairs is at least `threshold`.
    /// Returns groups of indices into `vectors`.
    static func groups(_ vectors: [[Float]], threshold: Float) -> [[Int]] {
        var clusters = vectors.indices.map { [$0] }
        var sim = vectors.map { a in vectors.map { b in cosineSimilarity(a, b) } }
        while true {
            var best: (i: Int, j: Int, sim: Float)?
            for i in clusters.indices {
                for j in (i + 1) ..< clusters.count where sim[i][j] >= threshold && sim[i][j] > (best?.sim ?? -2) {
                    best = (i, j, sim[i][j])
                }
            }
            guard let (i, j, _) = best else { return clusters }
            // Lance–Williams: the merged cluster's mean similarity to every other one.
            let (ni, nj) = (Float(clusters[i].count), Float(clusters[j].count))
            for k in clusters.indices where k != i && k != j {
                sim[i][k] = (ni * sim[i][k] + nj * sim[j][k]) / (ni + nj)
                sim[k][i] = sim[i][k]
            }
            clusters[i] += clusters[j]
            clusters.remove(at: j)
            sim.remove(at: j)
            for k in sim.indices { sim[k].remove(at: j) }
        }
    }

    /// The meeting voice: mean of the DISTINCT embeddings of the record's
    /// non-excluded lines — the math of `SpeakerRepository.perMeetingVoices`.
    private func meetingVoice(_ member: ListenQueueItem.Member) async throws -> [Float]? {
        let vectors = try await db.reader.read { db in
            try Data.fetchAll(db, sql: """
                SELECT DISTINCT embedding FROM transcript_segments
                WHERE meetingId = ? AND speakerId = ? AND embedding IS NOT NULL AND isExcluded = 0
                """, arguments: [member.meetingId, member.speakerId])
        }.map(Speaker.decodeEmbedding).filter { $0.count == 256 }
        guard !vectors.isEmpty else { return nil }
        return SpeakerRepository.naiveMean(vectors)
    }

    /// The meeting's non-excluded lines as a fragment needs them: the voice's
    /// own lines whole, everyone else's as a time on a track with no speaker
    /// and no text. The full record drags a 1 KB embedding per line, and a
    /// queue of 44 voices reads 54 000 of them.
    private func lines(of member: ListenQueueItem.Member) async throws -> [TranscriptSegment] {
        try await db.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, IFNULL(speakerId = :speaker, 0) AS own, source, startTime, endTime,
                       CASE WHEN speakerId = :speaker THEN text ELSE '' END AS text
                FROM transcript_segments
                WHERE meetingId = :meeting AND isExcluded = 0
                ORDER BY startTime
                """, arguments: ["speaker": member.speakerId, "meeting": member.meetingId])
                .map { row in
                    TranscriptSegment(
                        id: row["id"], meetingId: member.meetingId, speakerId: row["own"] ? member.speakerId : nil,
                        source: row["source"], startTime: row["startTime"], endTime: row["endTime"], text: row["text"]
                    )
                }
        }
    }

    /// The candidate's longest line in their latest meeting of the space other
    /// than the item's own. Meeting first, then the line, both found in
    /// idx_segments_voice; only the winning line is read from the table — a
    /// plain ORDER BY over a person's lines read every one of them (51 000 for
    /// the owner of the measured database).
    private func sample(of speakerId: String, space: EmbeddingSpace, besides meetingId: String) async throws
        -> ListenQueueItem.Fragment?
    {
        try await db.reader.read { db in
            try Row.fetchOne(db, sql: """
                SELECT meetingId, startTime, endTime, source, text FROM transcript_segments WHERE id = (
                    SELECT ts.id FROM transcript_segments ts
                    WHERE ts.speakerId = :speaker AND ts.isExcluded = 0 AND ts.meetingId = (
                        SELECT m.id FROM meetings m
                        WHERE m.id <> :besides AND \(space.meetingFilterSQL)
                          AND EXISTS (SELECT 1 FROM transcript_segments e
                                      WHERE e.speakerId = :speaker AND e.meetingId = m.id AND e.isExcluded = 0)
                        ORDER BY m.startTime DESC LIMIT 1)
                    ORDER BY (ts.endTime - ts.startTime) DESC LIMIT 1)
                """, arguments: ["speaker": speakerId, "besides": meetingId])
        }.map { row in
            ListenQueueItem.Fragment(
                meetingId: row["meetingId"], start: row["startTime"], end: row["endTime"],
                track: SegmentSource(rawValue: row["source"]) ?? .mic, text: row["text"]
            )
        }
    }

    /// Share of the voice's seconds lying under `skipped` marks of its track.
    static func skippedShare(of segments: [TranscriptSegment], verdicts: [MeetingMark]) -> Double {
        let skips = verdicts.filter { $0.kind == .skipped }
        let total = segments.reduce(0) { $0 + max($1.endTime - $1.startTime, 0) }
        guard total > 0, !skips.isEmpty else { return 0 }
        let covered = segments.reduce(0.0) { sum, segment in
            sum + MarkSpans.elementary(segment.startTime, segment.endTime, skips.filter { $0.track == segment.source })
                .filter { $0.covering != nil }
                .reduce(0) { $0 + $1.length }
        }
        return covered / total
    }

    /// Runs of the speaker's non-excluded lines per track: neighbours glue
    /// across a pause ≤ `gap` when no other line of that track starts in
    /// between. Longest first.
    static func fragments(of speakerId: String, in segments: [TranscriptSegment], gap: Double)
        -> [ListenQueueItem.Fragment]
    {
        var result: [ListenQueueItem.Fragment] = []
        for (track, lines) in Dictionary(grouping: segments.filter { !$0.isExcluded }, by: \.source) {
            var run: [TranscriptSegment] = []
            func close() {
                guard let first = run.first, let last = run.last else { return }
                result.append(.init(
                    meetingId: first.meetingId, start: first.startTime, end: last.endTime, track: track,
                    text: run.map(\.text).joined(separator: " ")
                ))
                run = []
            }
            for line in lines.sorted(by: { $0.startTime < $1.startTime }) {
                guard line.speakerId == speakerId else {
                    close()
                    continue
                }
                if let last = run.last, line.startTime - last.endTime > gap { close() }
                run.append(line)
            }
            close()
        }
        return result.sorted { $0.length != $1.length ? $0.length > $1.length : $0.start < $1.start }
    }
}
