import Foundation
import GRDB

struct SpeakerInfo: Sendable {
    let speaker: Speaker
    let meetingCount: Int
    let lastMeetingDate: Date?
    var totalSpeakingSeconds: Double = 0
}

struct SpeakerRepository {
    private let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: - Speakers

    func all() async throws -> [Speaker] {
        try await db.reader.read { db in
            try Speaker.order(Speaker.Columns.nameEn).fetchAll(db)
        }
    }

    func find(_ id: String) async throws -> Speaker? {
        try await db.reader.read { db in
            try Speaker.fetchOne(db, key: id)
        }
    }

    func findMe() async throws -> Speaker? {
        try await db.reader.read { db in
            try Speaker.filter(Speaker.Columns.isMe == true).fetchOne(db)
        }
    }

    /// Speakers that have a canonical in the given space. The returned records
    /// carry that space's vector in their `embedding` field (SQL alias) so pool
    /// builders stay space-agnostic — do NOT `save()` these instances: in `.v2`
    /// mode that would write a WeSpeaker vector into the v1 column.
    func speakersWithEmbeddings(space: EmbeddingSpace = .v1) async throws -> [Speaker] {
        try await db.reader.read { db in
            try Speaker.fetchAll(db, sql: """
                SELECT id, nameEn, nameRu, nickname, isMe, isConfirmed, createdAt,
                       \(space.rawValue) AS embedding
                FROM speakers
                WHERE \(space.rawValue) IS NOT NULL
                ORDER BY nameEn
                """)
        }
    }

    /// Confirmed enrolled speakers with embeddings, returned as lightweight tuples
    /// for the drift monitor. Decoded once here so the monitor
    /// doesn't fight `Speaker`'s nullable fields and ordering rules.
    func confirmedSpeakersWithEmbeddings(space: EmbeddingSpace = .v1) async throws
        -> [(id: String, name: String, canonical: [Float])]
    {
        try await db.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, COALESCE(nameRu, nameEn, nickname, '?') AS name,
                       \(space.rawValue) AS embedding
                FROM speakers
                WHERE isConfirmed = 1 AND \(space.rawValue) IS NOT NULL
                ORDER BY name
                """)
                .compactMap { row -> (id: String, name: String, canonical: [Float])? in
                    guard let blob: Data = row["embedding"] else { return nil }
                    let canonical = Speaker.decodeEmbedding(blob)
                    guard canonical.count == 256 else { return nil }
                    return (id: row["id"], name: row["name"], canonical: canonical)
                }
        }
    }

    /// Total transcript_segments count per speaker, for the given ids. Used by the
    /// two-stage matcher to filter out low-data canonicals — they
    /// produce noisy embeddings that match unrelated voices.
    ///
    /// `excludingMeeting`: the meeting being (re)processed. Its previous
    /// transcript stays until the new one replaces it, and must not count —
    /// the pool is the same as when a reprocess deleted that transcript first.
    func segmentCounts(for speakerIds: [String], excludingMeeting: String? = nil) async throws -> [String: Int] {
        guard !speakerIds.isEmpty else { return [:] }
        return try await db.reader.read { db in
            let placeholders = speakerIds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT speakerId, COUNT(*) AS n
                FROM transcript_segments
                WHERE speakerId IN (\(placeholders)) AND meetingId IS NOT ?
                GROUP BY speakerId
                """, arguments: StatementArguments(speakerIds) + [excludingMeeting])
            var out: [String: Int] = [:]
            for row in rows {
                let id: String = row["speakerId"]
                let n: Int = row["n"]
                out[id] = n
            }
            return out
        }
    }

    /// One speaker's canonical in the given space, decoded. Used by the mic
    /// ("me") matching path, which needs the space matching the active diarizer.
    func canonicalArray(speakerId: String, space: EmbeddingSpace) async throws -> [Float]? {
        try await db.reader.read { db in
            let blob = try Data.fetchOne(db, sql: """
                SELECT \(space.rawValue) FROM speakers
                WHERE id = ? AND \(space.rawValue) IS NOT NULL
                """, arguments: [speakerId])
            return blob.map { Speaker.decodeEmbedding($0) }
        }
    }

    /// Tunable knobs for canonical recalculation. See `recalculateEmbedding`.
    struct RecalcConfig {
        /// Fraction of segments (sorted by similarity to the rough mean) to keep
        /// for the second-pass clean mean. 0.5 = top 50%. Empirical default —
        /// dropped poisoned-pair pairwise sim from 0.94 to 0.65 max in our audit.
        var keepFraction: Double
        /// Minimum number of segments required after filtering. Falls back to
        /// keeping all if too few. Below this threshold the canonical is too
        /// shaky to publish.
        var minSegmentsAfterFilter: Int
        /// If the recomputed canonical has cosine sim greater than this to any
        /// OTHER confirmed enrolled speaker's canonical, the update is rejected
        /// and a warning is logged. Hard "two distinct people can't sound the
        /// same" constraint — Per space: 0.6 was calibrated on
        /// v1; in v2 (WeSpeaker) honest lookalikes of different people reach
        /// 0.71 and poisoned pairs start at 0.82 (guard-rescue-and-v2-canon).
        var identityInvariantThresholds: [EmbeddingSpace: Float]
        /// Weight saturation for meeting voices (speaker-row-per-mint,
        /// design § решение 4): weight = min(speechSeconds, cap) / cap — grows
        /// while material is scarce, flat once there is enough, so hundreds of
        /// centroid copies cannot outvote a handful of fresh meetings.
        var weightCapSeconds: Double = 60
        /// A meeting with less embedded speech than this never enters the
        /// canonical — random and misattributed scraps.
        var minMeetingSeconds: Double = 10
        /// Meetings with less speech than this do not vote on who the outliers
        /// are (they are still ranked and may stay): nine scraps of 13–40 s
        /// used to outvote one meeting of 3791 s and drop it as the outlier.
        var outlierVoteFloorSeconds: Double = 60
        /// Only this many most recent meetings (by meeting date) count.
        var maxMeetings: Int = 30
        /// A speaker with no canonical in the space gets one even on collision.
        /// On where a person attributed the voices (rename, reassign, merge):
        /// otherwise a new person next to a polluted record never enters the
        /// pool. Off on automatic paths (`automatic`), where nobody vouched
        /// for the voices — a foreign-voice enrollment must stay rejected.
        var firstCanonicalDespiteCollision = true
        /// Identity invariant by separability — replaces the plain threshold
        /// in the spaces listed in its `hardCap` (v2). The plain thresholds
        /// above stay for v1 and for speakers with too few voices.
        var separability = SeparabilityCheck.Config()

        static let `default` = RecalcConfig(
            keepFraction: 0.5,
            minSegmentsAfterFilter: 5,
            identityInvariantThresholds: [.v1: 0.6, .v2: 0.75]
        )

        /// Pipeline, enrollment, marks, reprocess.
        static let automatic: RecalcConfig = {
            var config = RecalcConfig.default
            config.firstCanonicalDespiteCollision = false
            return config
        }()

        func identityInvariantThreshold(for space: EmbeddingSpace) -> Float {
            identityInvariantThresholds[space] ?? 0.6
        }
    }

    /// What a canonical recalculation did in one space — reported back to the
    /// command that triggered it instead of living only in the log.
    enum RecalcOutcome: Equatable, CustomStringConvertible {
        case saved
        /// The speaker had no canonical in this space, so the collision did
        /// not block the first one (a new person next to a polluted record).
        case savedDespiteCollision(with: String, sim: Float)
        case rejected(with: String, sim: Float)
        /// Meeting voices cannot be told apart from another confirmed speaker.
        /// `share` — speech fraction of the voices closer to `from` than to
        /// their own canonical; `meetings` — their ids, most speech first
        /// (empty when only the typical gap is too small).
        case inseparable(from: String, share: Float, meetings: [String])
        /// No voices in this space.
        case skipped

        var description: String {
            switch self {
            case .saved: "saved"
            case .savedDespiteCollision(let name, let sim):
                "saved despite \(String(format: "%.3f", sim)) to '\(name)'"
            case .rejected(let name, let sim):
                "rejected (\(String(format: "%.3f", sim)) to '\(name)', old kept)"
            case .inseparable(let name, _, let meetings) where meetings.isEmpty:
                "rejected: voices barely closer to own canonical than to '\(name)'; old kept"
            case .inseparable(let name, let share, let meetings):
                "rejected: \(meetings.count) voice(s) (\(Int((share * 100).rounded()))% of speech) closer to "
                    + "'\(name)' — meetings " + meetings.prefix(5).map { String($0.prefix(8)) }.joined(separator: ", ")
                    + (meetings.count > 5 ? " +\(meetings.count - 5) more" : "") + "; old kept"
            case .skipped: "skipped"
            }
        }

        /// "canonical v1: skipped, v2: saved" for command responses.
        static func summary(_ outcomes: [EmbeddingSpace: RecalcOutcome]) -> String {
            "canonical " + EmbeddingSpace.allCases.compactMap { space in
                outcomes[space].map { "\(space): \($0)" }
            }.joined(separator: ", ")
        }
    }

    /// Recalculate a speaker's canonical embedding from meeting voices
    /// (speaker-row-per-mint, design § решение 4): one deduped vector per
    /// meeting, saturated weights, recency by meeting date. Two safeguards:
    ///   1. **Self-cleaning**: outlier meetings (foreign labeling) drop out
    ///      whole, so one contaminated meeting can't tip the canonical.
    /// 2. **Identity-space invariant**: refuse to save a
    ///      canonical acoustically too close to another confirmed enrolled
    ///      speaker — such a collision is almost always poisoning.
    @discardableResult
    func recalculateEmbedding(
        speakerId: String,
        config: RecalcConfig = .default
    ) async throws -> [EmbeddingSpace: RecalcOutcome] {
        // Dual-pool transition: the two embedder spaces share dim 256
        // and are indistinguishable by inspection, so each canonical column is
        // recomputed strictly from segments of meetings processed by the matching
        // diarizer. A space with no segments is left untouched.
        var outcomes: [EmbeddingSpace: RecalcOutcome] = [:]
        for space in EmbeddingSpace.allCases {
            outcomes[space] = try await recalculateEmbedding(speakerId: speakerId, space: space, config: config)
        }
        return outcomes
    }

    @discardableResult
    func recalculateEmbedding(
        speakerId: String,
        space: EmbeddingSpace,
        config: RecalcConfig = .default
    ) async throws -> RecalcOutcome {
        Log.debug("recalculateEmbedding[\(space)]: start for speaker \(speakerId)")

        // Meeting voices, not segments: offline segments carry copies of the
        // cluster centroid, so a segment-level sample is a handful of vectors
        // weighted by talkativeness. One voice per meeting, saturated weights,
        // outlier meetings dropped whole (design § решение 4).
        let voices = try await perMeetingVoices(speakerId: speakerId, space: space, config: config)
        guard !voices.isEmpty else {
            Log.debug("recalculateEmbedding[\(space)]: no meeting with segment embeddings clears the \(config.minMeetingSeconds)s floor for speaker \(speakerId)")
            return .skipped
        }

        guard let selection = Self.canonicalSelection(voices, config: config) else {
            Log.info("recalculateEmbedding[\(space)]: skipping for \(speakerId) — no meeting clears the \(config.minMeetingSeconds)s speech floor")
            return .skipped
        }
        let canonical = selection.canonical

        // Identity invariant. v2: separability of the meeting voices against
        // the neighbours' LIVE canonicals. v1: the plain threshold against the
        // stored canonicals of other confirmed enrolled speakers.
        var collision: (otherId: String, otherName: String, sim: Float, rejection: RecalcOutcome, why: String)?
        if config.separability.hardCap[space] != nil {
            let result = try await separability(speakerId: speakerId, selection: selection, space: space, config: config)
            switch result.verdict {
            case .separable:
                break
            case .tooSimilar(let id, let name, let sim):
                collision = (id, name, sim, .rejected(with: name, sim: sim),
                             "new canonical sim \(String(format: "%.3f", sim)) to the live canonical is over the limit")
            case .inseparable(let id, let name, let sim, let share, let meetings):
                collision = (id, name, sim, .inseparable(from: name, share: share, meetings: meetings),
                             "voices not separable — \(result.logDescription)")
            }
        } else {
            let threshold = config.identityInvariantThreshold(for: space)
            if let found = try await findCanonicalCollision(
                for: speakerId, against: canonical, space: space, threshold: threshold
            ) {
                collision = (found.otherId, found.otherName, found.sim,
                             .rejected(with: found.otherName, sim: found.sim),
                             "new canonical sim \(String(format: "%.3f", found.sim)) > \(threshold)")
            }
        }

        var outcome = RecalcOutcome.saved
        if let collision {
            // No canonical yet and a person attributed these voices: rejecting
            // would keep them out of the pool for being close to a polluted record.
            guard config.firstCanonicalDespiteCollision,
                  try await canonicalArray(speakerId: speakerId, space: space) == nil
            else {
                Log.warning("""
                    recalculateEmbedding[\(space)]: REJECTED for \(speakerId) against \
                    '\(collision.otherName)' (id \(collision.otherId)): \(collision.why). Old canonical kept; \
                    investigate whether these two speaker records are actually the same person \
                    (run mergeSpeakers) or if the source segments are contaminated.
                    """)
                return collision.rejection
            }
            Log.warning("""
                recalculateEmbedding[\(space)]: saving FIRST canonical for \(speakerId) despite \
                '\(collision.otherName)' (id \(collision.otherId)): \(collision.why) — \
                one of the two may carry the other's voice.
                """)
            outcome = .savedDespiteCollision(with: collision.otherName, sim: collision.sim)
        }

        let data = Speaker.encodeEmbedding(canonical)
        Log.info("recalculateEmbedding[\(space)]: saving canonical from \(voices.count) meeting voice(s) for speaker \(speakerId)")
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE speakers SET \(space.rawValue) = ? WHERE id = ?",
                arguments: [data, speakerId]
            )
        }
        return outcome
    }

    /// One aggregated voice per meeting: the mean of that meeting's segment
    /// vectors weighted by each segment's seconds (segment-own-voice § 6). A
    /// meeting of centroid copies still yields the centroid; a 5 s rescued
    /// piece weighs 5 s, not as much as the whole cluster. Also the building
    /// block for cross-meeting regrouping.
    struct MeetingVoice {
        let meetingId: String
        let meetingStart: Date
        let embedding: [Float]
        /// Seconds of this speaker's embedded, non-excluded speech there.
        let speechSeconds: Double
    }

    /// Only meetings that can enter the canonical are returned — the same
    /// floor and recency cut `canonicalFromVoices` applies — so blobs are read
    /// for those alone, through a cursor that keeps one row in memory.
    func perMeetingVoices(
        speakerId: String,
        space: EmbeddingSpace,
        config: RecalcConfig = .default
    ) async throws -> [MeetingVoice] {
        try await db.reader.read { db -> [MeetingVoice] in
            var trace = PerfTrace("perMeetingVoices(\(speakerId.prefix(8)))")
            defer { trace.finish() }
            let aggs = try Row.fetchAll(db, sql: """
                SELECT ts.meetingId, m.startTime AS meetingStart,
                       SUM(MAX(ts.endTime - ts.startTime, 0)) AS seconds
                FROM transcript_segments ts
                JOIN meetings m ON m.id = ts.meetingId
                WHERE ts.speakerId = ? AND ts.embedding IS NOT NULL
                  AND ts.isExcluded = 0
                  AND \(space.meetingFilterSQL)
                GROUP BY ts.meetingId
                """, arguments: [speakerId])
            let selected = aggs
                .filter { ($0["seconds"] as Double) >= config.minMeetingSeconds }
                .sorted { ($0["meetingStart"] as Date) > ($1["meetingStart"] as Date) }
                .prefix(config.maxMeetings)
            guard !selected.isEmpty else { return [] }
            trace.checkpoint("aggregate")

            let ids = selected.map { $0["meetingId"] as String }
            var sums: [String: [Float]] = [:]
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT ts.meetingId, ts.embedding, MAX(ts.endTime - ts.startTime, 0) AS seconds
                FROM transcript_segments ts
                JOIN meetings m ON m.id = ts.meetingId
                WHERE ts.speakerId = ? AND ts.embedding IS NOT NULL
                  AND ts.isExcluded = 0
                  AND \(space.meetingFilterSQL)
                  AND ts.meetingId IN (\(databaseQuestionMarks(count: ids.count)))
                """, arguments: StatementArguments([speakerId] + ids))
            while let row = try cursor.next() {
                // Both embedder spaces are 256-dim; anything else is a corrupt
                // or legacy blob and must not reach the cosine math.
                let vector = Speaker.decodeEmbedding(row["embedding"] as Data)
                guard vector.count == 256 else { continue }
                let weight = Float(row["seconds"] as Double)
                let meetingId: String = row["meetingId"]
                var sum = sums[meetingId] ?? [Float](repeating: 0, count: 256)
                for i in 0 ..< 256 { sum[i] += weight * vector[i] }
                sums[meetingId] = sum
            }
            trace.checkpoint("weighted sum")

            return selected.compactMap { row in
                let meetingId: String = row["meetingId"]
                guard let sum = sums[meetingId] else { return nil }
                return MeetingVoice(
                    meetingId: meetingId,
                    meetingStart: row["meetingStart"],
                    embedding: Self.l2Normalize(sum),
                    speechSeconds: row["seconds"]
                )
            }
        }
    }

    /// A meeting voice that entered the canonical, with its saturated weight.
    struct WeightedVoice {
        let voice: MeetingVoice
        let weight: Float
    }

    struct CanonicalSelection {
        let canonical: [Float]
        let voices: [WeightedVoice]
        /// Recent meetings with enough speech that the outlier filter left
        /// out. Not in the canonical, but still this speaker's attributed
        /// speech: the separability check judges them too — a meeting that
        /// is really someone else is exactly what the filter drops.
        var dropped: [MeetingVoice] = []
    }

    /// The canonical alone — see `canonicalSelection`.
    static func canonicalFromVoices(
        _ voices: [MeetingVoice],
        config: RecalcConfig = .default
    ) -> [Float]? {
        canonicalSelection(voices, config: config)?.canonical
    }

    /// The v2 identity invariant for a candidate canonical, without writing:
    /// shortlist neighbours by their stored canonicals, rebuild each one's
    /// LIVE canonical from its current voices (stored only when it has none),
    /// and judge by the live ones — two stale stored canonicals cannot lock
    /// each other out. `shortlist: false` checks every confirmed speaker
    /// (the replay compares both).
    func separability(
        speakerId: String,
        selection: CanonicalSelection,
        space: EmbeddingSpace,
        config: RecalcConfig = .default,
        shortlist: Bool = true
    ) async throws -> SeparabilityCheck.Result {
        var trace = PerfTrace("separability[\(space)] \(speakerId)")
        let columns = try await confirmedSpeakersWithEmbeddings(space: space)
            .filter { $0.id != speakerId }
            .map { SeparabilityCheck.Neighbor(id: $0.id, name: $0.name, canonical: $0.canonical) }
        let chosen = shortlist
            ? SeparabilityCheck.shortlist(selection, columns: columns, config: config.separability)
            : columns
        trace.checkpoint("shortlist \(chosen.count)/\(columns.count)")
        var live: [SeparabilityCheck.Neighbor] = []
        for neighbor in chosen {
            let voices = try await perMeetingVoices(speakerId: neighbor.id, space: space)
            live.append(SeparabilityCheck.Neighbor(
                id: neighbor.id, name: neighbor.name,
                canonical: Self.canonicalFromVoices(voices, config: config) ?? neighbor.canonical
            ))
        }
        trace.checkpoint("live canonicals")
        let result = SeparabilityCheck.evaluate(selection, neighbors: live, config: config, space: space)
        trace.checkpoint("evaluate")
        trace.finish()
        return result
    }

    /// Pure core of the meeting-voice canonical — exposed for unit tests.
    /// nil when no meeting clears the speech floor.
    static func canonicalSelection(
        _ voices: [MeetingVoice],
        config: RecalcConfig = .default
    ) -> CanonicalSelection? {
        // Scraps out: a few misattributed seconds never enter the canonical.
        let eligible = voices.filter { $0.speechSeconds >= config.minMeetingSeconds }
        guard !eligible.isEmpty else { return nil }

        // Recency by meeting date — old meetings are displaced by new ones.
        let recent = Array(
            eligible.sorted { $0.meetingStart > $1.meetingStart }.prefix(config.maxMeetings)
        )

        // Outlier meetings drop out WHOLE: rank voices by similarity to the
        // rough mean, keep the top fraction. Below 4 points an outlier is
        // indistinguishable from the crowd — keep everything.
        var kept = recent
        var dropped: [MeetingVoice] = []
        if recent.count >= 4 {
            // No meeting clears the floor — everyone votes, as before.
            let voters = recent.filter { $0.speechSeconds >= config.outlierVoteFloorSeconds }
            let rough = l2Normalize(naiveMean((voters.isEmpty ? recent : voters).map(\.embedding)))
            let target = Int((Double(recent.count) * config.keepFraction).rounded())
            let keepN = min(recent.count, max(3, target))
            let ranked = recent
                .sorted { cosineSimilarity($0.embedding, rough) > cosineSimilarity($1.embedding, rough) }
            kept = Array(ranked.prefix(keepN))
            dropped = Array(ranked.dropFirst(keepN))
        }

        // Saturated weight: grows with material up to the cap, then flat.
        guard let dim = kept.first?.embedding.count else { return nil }
        let cap = max(config.weightCapSeconds, 1)
        var sum = [Float](repeating: 0, count: dim)
        var total: Float = 0
        var selected: [WeightedVoice] = []
        for voice in kept where voice.embedding.count == dim {
            let weight = Float(min(voice.speechSeconds, cap) / cap)
            guard weight > 0 else { continue }
            for i in 0 ..< dim { sum[i] += weight * voice.embedding[i] }
            total += weight
            selected.append(WeightedVoice(voice: voice, weight: weight))
        }
        guard total > 0 else { return nil }
        for i in 0 ..< dim { sum[i] /= total }
        return CanonicalSelection(canonical: l2Normalize(sum), voices: selected, dropped: dropped)
    }

    /// Pure helper — exposed for unit tests.
    /// Returns `nil` when the input has fewer than `minSegmentsAfterFilter`
    /// segments. Caller should then **skip the canonical update entirely** rather
    /// than publish a shaky mean from too little data.
    static func purifiedCentroid(
        embeddings: [[Float]],
        config: RecalcConfig = .default
    ) -> [Float]? {
        guard let first = embeddings.first, !first.isEmpty, embeddings.count >= config.minSegmentsAfterFilter else { return nil }
        let dim = first.count

        // Pass 1 — rough mean, L2 normalized.
        let rough = l2Normalize(naiveMean(embeddings))

        // Per-segment sim to rough mean. Sort desc so we can take the top.
        let scored = embeddings.map { (emb: $0, sim: cosineSimilarity($0, rough)) }
            .sorted { $0.sim > $1.sim }

        // Keep top-fraction, bounded below by the segment-count floor and above
        // by the input size (in case keepFraction was set to 1.0 or larger).
        let target = Int((Double(embeddings.count) * config.keepFraction).rounded())
        let keepN = min(embeddings.count, max(config.minSegmentsAfterFilter, target))
        let kept = Array(scored.prefix(keepN)).map(\.emb)

        // Pass 2 — clean mean from kept set, L2 normalized.
        var clean = [Float](repeating: 0, count: dim)
        for emb in kept {
            for i in 0 ..< dim { clean[i] += emb[i] }
        }
        let n = Float(kept.count)
        for i in 0 ..< dim { clean[i] /= n }
        return l2Normalize(clean)
    }

    /// v1 only. Look for any other confirmed enrolled speaker whose STORED canonical is too close to
    /// the candidate canonical. Returns the closest collision above threshold, or
    /// nil if none. Self is excluded.
    private func findCanonicalCollision(
        for selfSpeakerId: String,
        against candidate: [Float],
        space: EmbeddingSpace,
        threshold: Float
    ) async throws -> (otherId: String, otherName: String, sim: Float)? {
        let others: [(id: String, name: String, embedding: Data)] = try await db.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, COALESCE(nameRu, nameEn, nickname, '?') AS name,
                       \(space.rawValue) AS embedding
                FROM speakers
                WHERE isConfirmed = 1 AND \(space.rawValue) IS NOT NULL AND id != ?
                """, arguments: [selfSpeakerId])
                .map { (id: $0["id"], name: $0["name"], embedding: $0["embedding"]) }
        }
        var worst: (id: String, name: String, sim: Float)?
        for o in others {
            let canon = Speaker.decodeEmbedding(o.embedding)
            guard canon.count == candidate.count else { continue }
            let sim = cosineSimilarity(candidate, canon)
            if sim > threshold, worst == nil || sim > worst!.sim {
                worst = (o.id, o.name, sim)
            }
        }
        return worst.map { (otherId: $0.id, otherName: $0.name, sim: $0.sim) }
    }

    /// Element-wise mean of equal-length vectors, no normalization. Internal helper.
    static func naiveMean(_ vectors: [[Float]]) -> [Float] {
        let dim = vectors[0].count
        var acc = [Float](repeating: 0, count: dim)
        for v in vectors {
            for i in 0 ..< dim { acc[i] += v[i] }
        }
        let n = Float(vectors.count)
        for i in 0 ..< dim { acc[i] /= n }
        return acc
    }

    private func naiveMean(_ vectors: [[Float]]) -> [Float] { Self.naiveMean(vectors) }

    private static func l2Normalize(_ v: [Float]) -> [Float] {
        var sumsq: Float = 0
        for x in v { sumsq += x * x }
        let mag = sumsq.squareRoot()
        guard mag > 0 else { return v }
        return v.map { $0 / mag }
    }

    private func l2Normalize(_ v: [Float]) -> [Float] { Self.l2Normalize(v) }

    func save(_ speaker: Speaker) async throws {
        try await db.writer.write { db in
            try speaker.save(db)
        }
    }

    func rename(_ id: String, name: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE speakers SET nameEn = ? WHERE id = ?",
                arguments: [name, id]
            )
        }
    }

    // MARK: - Meeting Speaker Mappings

    /// All meeting→speakers mappings in a single round-trip. Used by sidebar filter and speaker page.
    /// A pair needs a kept line, as in `spokenLinks`: a voice whose lines are all hidden did not speak there.
    func meetingSpeakerMap() async throws -> [String: Set<String>] {
        try await db.reader.read { db in
            var result: [String: Set<String>] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT ms.meetingId, ms.speakerId FROM meeting_speakers ms
                WHERE EXISTS (
                    SELECT 1 FROM transcript_segments t
                    WHERE t.speakerId = ms.speakerId AND t.meetingId = ms.meetingId AND t.isExcluded = 0
                )
                """)
            for row in rows {
                let meetingId: String = row["meetingId"]
                let speakerId: String = row["speakerId"]
                result[meetingId, default: []].insert(speakerId)
            }
            return result
        }
    }

    func speakersForMeeting(_ meetingId: String) async throws -> [(speaker: Speaker, label: String?)] {
        try await db.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, ms.diarizationLabel
                FROM speakers s
                JOIN meeting_speakers ms ON ms.speakerId = s.id
                WHERE ms.meetingId = ?
                ORDER BY s.nameEn
                """, arguments: [meetingId])

            return try rows.map { row in
                let speaker = try Speaker(row: row)
                let label: String? = row["diarizationLabel"]
                return (speaker: speaker, label: label)
            }
        }
    }

    func assignSpeakerToMeeting(
        meetingId: String,
        speakerId: String,
        diarizationLabel: String?
    ) async throws {
        try await db.writer.write { db in
            // Verify speaker still exists (may have been merged/deleted during pipeline)
            let speakerExists = try Speaker.filter(key: speakerId).fetchCount(db) > 0
            guard speakerExists else {
                Log.info("Speaker \(speakerId) no longer exists, skipping meeting link")
                return
            }
            let mapping = MeetingSpeaker(
                meetingId: meetingId,
                speakerId: speakerId,
                diarizationLabel: diarizationLabel
            )
            try mapping.save(db)
        }
    }

    /// Find a speaker by any of nameEn / nameRu / nickname, or create one.
    ///
    /// Historical bug (2026-05-07): the original implementation
    /// searched only `nameEn`, so when the user renamed a fresh `speaker_N` to
    /// "Alice Example", we created a NEW Speaker with nameEn="Alice Example"
    /// even though a record with nameRu="Alice Example" already existed for the
    /// same person. Result: duplicate confirmed records that DriftMonitor flagged
    /// at sim 0.96+. Fixed by matching against all three name fields.
    func findOrCreateSpeaker(name: String, isMe: Bool = false) async throws -> Speaker {
        try await db.writer.write { try Self.findOrCreate($0, name: name, isMe: isMe) }
    }

    private static func findOrCreate(_ db: Database, name: String, isMe: Bool = false) throws -> Speaker {
        // Auto `speaker_N` labels are per-meeting slot names, never identities —
        // binding them by name is how one speaker_1 row collected 72 meetings
        // (speaker-row-per-mint). The guard lives HERE so every caller is
        // covered, including the UI rename/reassign paths where a user can
        // type "speaker_3" by hand.
        if !Speaker.isAutoLabel(name), let existing = try Speaker.fetchOne(db, sql: """
            SELECT * FROM speakers
            WHERE nameEn = ? OR nameRu = ? OR nickname = ?
            LIMIT 1
            """, arguments: [name, name, name]) {
            return existing
        }
        return try create(db, name: name, isMe: isMe)
    }

    /// Always creates a fresh speaker row — never reuses one by name. The
    /// pipeline's mint path for auto `speaker_N` labels: an auto label is a
    /// per-meeting slot name, not an identity to look up (speaker-row-per-mint).
    func createSpeaker(name: String, isMe: Bool = false) async throws -> Speaker {
        try await db.writer.write { try Self.create($0, name: name, isMe: isMe) }
    }

    private static func create(_ db: Database, name: String, isMe: Bool) throws -> Speaker {
        let existingHues = try Double.fetchAll(db, sql: "SELECT hue FROM speakers WHERE hue IS NOT NULL")
        let speaker = Speaker(nameEn: name, isMe: isMe, hue: SpeakerHueMath.nextHue(existing: existingHues))
        try speaker.save(db)
        return speaker
    }

    // MARK: - Persistent Hue

    func updateHue(_ speakerId: String, hue: Double) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE speakers SET hue = ? WHERE id = ?",
                arguments: [hue, speakerId]
            )
        }
    }

    /// speakerId → stored hue, for the view-facing SpeakerHue resolver.
    func hueMap() async throws -> [String: Double] {
        try await db.reader.read { db in
            var result: [String: Double] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT id, hue FROM speakers WHERE hue IS NOT NULL")
            for row in rows {
                result[row["id"]] = row["hue"]
            }
            return result
        }
    }

    /// Backfill hues for speakers created by legacy paths that bypassed
    /// findOrCreateSpeaker. Cheap no-op when everyone has a hue.
    func assignMissingHues() async throws {
        try await db.writer.write { db in
            let missing = try String.fetchAll(
                db, sql: "SELECT id FROM speakers WHERE hue IS NULL ORDER BY createdAt, id"
            )
            guard !missing.isEmpty else { return }
            var existing = try Double.fetchAll(db, sql: "SELECT hue FROM speakers WHERE hue IS NOT NULL")
            for id in missing {
                let hue = SpeakerHueMath.nextHue(existing: existing)
                try db.execute(sql: "UPDATE speakers SET hue = ? WHERE id = ?", arguments: [hue, id])
                existing.append(hue)
            }
        }
    }

    // MARK: - Speaker Info with Meeting Counts

    func speakersWithMeetingCounts() async throws -> [SpeakerInfo] {
        try await db.reader.read { db in
            // Speaking time comes from a single pre-aggregated pass over
            // transcript_segments — a correlated per-speaker subquery scanned
            // the table once per speaker (2.25s vs 0.04s at 100 speakers/92k
            // segments).
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, COUNT(DISTINCT ms.meetingId) AS meetingCount,
                       MAX(m.startTime) AS lastMeetingDate,
                       COALESCE(agg.total, 0) AS totalSpeakingSeconds
                FROM speakers s
                LEFT JOIN meeting_speakers ms ON ms.speakerId = s.id
                LEFT JOIN meetings m ON m.id = ms.meetingId
                LEFT JOIN (SELECT speakerId, SUM(endTime - startTime) AS total
                           FROM transcript_segments
                           GROUP BY speakerId) agg ON agg.speakerId = s.id
                GROUP BY s.id
                ORDER BY s.nameEn
                """)

            return rows.map { row in
                let speaker = Speaker(
                    id: row["id"],
                    nameEn: row["nameEn"],
                    nickname: row["nickname"],
                    nameRu: row["nameRu"],
                    isMe: row["isMe"],
                    isConfirmed: row["isConfirmed"],
                    createdAt: row["createdAt"],
                    embedding: row["embedding"],
                    hue: row["hue"]
                )
                let meetingCount: Int = row["meetingCount"]
                let lastMeetingDate: Date? = row["lastMeetingDate"]
                let totalSpeakingSeconds: Double = row["totalSpeakingSeconds"]
                return SpeakerInfo(
                    speaker: speaker,
                    meetingCount: meetingCount,
                    lastMeetingDate: lastMeetingDate,
                    totalSpeakingSeconds: totalSpeakingSeconds
                )
            }
        }
    }

    func meetingsForSpeaker(_ speakerId: String) async throws -> [Meeting] {
        try await db.reader.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT m.*
                FROM meetings m
                JOIN meeting_speakers ms ON ms.meetingId = m.id
                WHERE ms.speakerId = ?
                ORDER BY m.startTime DESC
                """, arguments: [speakerId])
        }
    }

    /// Who spoke in which of these meetings, and those speakers, for the chip
    /// filter. A pair needs a kept line: a meeting_speakers row whose lines all
    /// went to someone else names nobody.
    func spokenLinks(meetingIds: [String]) async throws -> (speakers: [Speaker], links: [SpeakerChipFilter.Link]) {
        guard !meetingIds.isEmpty else { return ([], []) }
        return try await db.reader.read { db in
            let links = try Row.fetchAll(db, sql: """
                SELECT ms.meetingId, ms.speakerId FROM meeting_speakers ms
                WHERE ms.meetingId IN (\(databaseQuestionMarks(count: meetingIds.count)))
                AND EXISTS (
                    SELECT 1 FROM transcript_segments t
                    WHERE t.speakerId = ms.speakerId AND t.meetingId = ms.meetingId AND t.isExcluded = 0
                )
                """, arguments: StatementArguments(meetingIds)).map { SpeakerChipFilter.Link(meetingId: $0["meetingId"], speakerId: $0["speakerId"]) }
            let speakers = try Speaker.filter(keys: Set(links.map(\.speakerId))).fetchAll(db)
            return (speakers, links)
        }
    }

    // MARK: - Profile

    /// The names, and the display name onto every line of the speaker, in one
    /// transaction: as two writes a failure between them left the new name on
    /// the record and the old one in the transcripts.
    func updateProfile(
        _ id: String,
        nameEn: String,
        nameRu: String?,
        nickname: String?
    ) async throws {
        try await db.writer.write { db in
            try db.execute(sql: """
                UPDATE speakers SET nameEn = ?, nameRu = ?, nickname = ? WHERE id = ?
                """, arguments: [nameEn, nameRu, nickname, id])
            guard let saved = try Speaker.fetchOne(db, key: id) else { return }
            try db.execute(sql: """
                UPDATE transcript_segments SET speakerLabel = ? WHERE speakerId = ?
                """, arguments: [saved.displayName, id])
        }
    }

    /// Update speakerLabel on all transcript segments for a given speaker.
    func updateSegmentLabelsForSpeaker(_ speakerId: String, newLabel: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: """
                UPDATE transcript_segments SET speakerLabel = ? WHERE speakerId = ?
                """, arguments: [newLabel, speakerId])
        }
    }

    // MARK: - Mark as Me

    func markAsMe(_ speakerId: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE speakers SET isMe = 0 WHERE isMe = 1")
            try db.execute(sql: "UPDATE speakers SET isMe = 1, isConfirmed = 1 WHERE id = ?", arguments: [speakerId])
        }
    }

    /// Mark a speaker as confirmed (user has verified their identity).
    func confirmSpeaker(_ speakerId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE speakers SET isConfirmed = 1 WHERE id = ?",
                arguments: [speakerId]
            )
        }
    }

    // MARK: - Cleanup

    /// Remove a speaker from a meeting if it has no segments there; delete the speaker if it has no meetings left.
    func cleanupSpeakerFromMeetingIfUnused(speakerId: String, meetingId: String) async throws {
        try await db.writer.write { db in
            let segmentCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_segments
                WHERE speakerId = ? AND meetingId = ?
                """, arguments: [speakerId, meetingId]) ?? 0

            guard segmentCount == 0 else { return }

            try db.execute(sql: """
                DELETE FROM meeting_speakers WHERE speakerId = ? AND meetingId = ?
                """, arguments: [speakerId, meetingId])

            let meetingCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM meeting_speakers WHERE speakerId = ?
                """, arguments: [speakerId]) ?? 0

            if meetingCount == 0 {
                try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [speakerId])
            }
        }
    }

    /// Remove meeting_speakers entries where the speaker has no segments in this meeting,
    /// then delete any speakers that are no longer referenced by any meeting.
    func cleanupOrphanedMeetingSpeakers(meetingId: String) async throws {
        try await db.writer.write { try Self.cleanupOrphanedMeetingSpeakers($0, meetingId: meetingId) }
    }

    private static func cleanupOrphanedMeetingSpeakers(_ db: Database, meetingId: String) throws {
        // Remove meeting_speakers links where speaker has no segments in this meeting
        try db.execute(sql: """
            DELETE FROM meeting_speakers
            WHERE meetingId = ? AND speakerId NOT IN (
                SELECT DISTINCT speakerId FROM transcript_segments
                WHERE meetingId = ? AND speakerId IS NOT NULL
            )
            """, arguments: [meetingId, meetingId])

        // Delete speakers no longer referenced by any meeting, segment or
        // verdict — temp ones only, the same rule as cleanupOrphanedSpeakers:
        // a person the user named, and the owner, outlive their meetings. A
        // verdict's speaker may be between segments while its meeting
        // reprocesses, and the cascade would drop the verdict.
        try db.execute(sql: """
            DELETE FROM speakers
            WHERE isConfirmed = 0 AND isMe = 0
            AND id NOT IN (SELECT DISTINCT speakerId FROM meeting_speakers)
            AND id NOT IN (
                SELECT DISTINCT speakerId FROM transcript_segments
                WHERE speakerId IS NOT NULL
            )
            AND id NOT IN (SELECT speakerId FROM meeting_marks WHERE speakerId IS NOT NULL)
            """)
    }

    /// Delete all temp (unconfirmed) speakers that have no meeting links and no segment references.
    func cleanupOrphanedSpeakers() async throws {
        try await db.writer.write { db in
            try db.execute(sql: """
                DELETE FROM speakers
                WHERE isConfirmed = 0
                AND id NOT IN (SELECT DISTINCT speakerId FROM meeting_speakers)
                AND id NOT IN (
                    SELECT DISTINCT speakerId FROM transcript_segments
                    WHERE speakerId IS NOT NULL
                )
                """)
        }
    }

    /// Remove ghost meeting_speaker links (no segments) and orphaned temp speakers.
    func cleanupGhostLinks(meetingId: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: """
                DELETE FROM meeting_speakers
                WHERE meetingId = ? AND speakerId NOT IN (
                    SELECT DISTINCT speakerId FROM transcript_segments
                    WHERE meetingId = ? AND speakerId IS NOT NULL
                )
                """, arguments: [meetingId, meetingId])

            try db.execute(sql: """
                DELETE FROM speakers
                WHERE isConfirmed = 0
                AND id NOT IN (SELECT DISTINCT speakerId FROM meeting_speakers)
                AND id NOT IN (
                    SELECT DISTINCT speakerId FROM transcript_segments
                    WHERE speakerId IS NOT NULL
                )
                """)
        }
    }

    // MARK: - Merge Speakers

    enum MergeError: Error, Equatable {
        case sourceNotFound(String)
    }

    /// Returns the target's canonical recalc outcome; empty when the recalc
    /// itself failed (the merge is committed either way).
    /// Throws `sourceNotFound` and changes nothing when any source id is unknown.
    /// `confirmTarget`: the merge screens' «this is a person I know», same transaction.
    @discardableResult
    func mergeSpeakers(
        targetId: String, sourceIds: [String], confirmTarget: Bool = false
    ) async throws -> [EmbeddingSpace: RecalcOutcome] {
        try await db.writer.write { db in
            if let missing = try sourceIds.first(where: { try !Speaker.exists(db, key: $0) }) {
                throw MergeError.sourceNotFound(missing)
            }
            for sourceId in sourceIds {
                // Update transcript_segments
                try db.execute(sql: """
                    UPDATE transcript_segments SET speakerId = ?, speakerLabel = (
                        -- Speaker.displayName, the label a profile save writes
                        SELECT COALESCE(NULLIF(nameRu, ''), NULLIF(nickname, ''), nameEn)
                        FROM speakers WHERE id = ?
                    ) WHERE speakerId = ?
                    """, arguments: [targetId, targetId, sourceId])

                // Handle meeting_speakers: delete duplicates first, then reassign
                try db.execute(sql: """
                    DELETE FROM meeting_speakers WHERE speakerId = ? AND meetingId IN (
                        SELECT meetingId FROM meeting_speakers WHERE speakerId = ?
                    )
                    """, arguments: [sourceId, targetId])
                try db.execute(
                    sql: "UPDATE meeting_speakers SET speakerId = ? WHERE speakerId = ?",
                    arguments: [targetId, sourceId]
                )

                // The owner mark moves with the voice: merging "me" into
                // another record deleted the only isMe row, and with it the
                // mic attribution and the foreign-voice rule.
                try db.execute(sql: """
                    UPDATE speakers SET isMe = 1, isConfirmed = 1
                    WHERE id = ? AND EXISTS (SELECT 1 FROM speakers WHERE id = ? AND isMe = 1)
                    """, arguments: [targetId, sourceId])

                // Verdicts follow the voice; the cascade below would drop them.
                try db.execute(
                    sql: "UPDATE meeting_marks SET speakerId = ? WHERE speakerId = ?",
                    arguments: [targetId, sourceId]
                )

                // Delete source speaker
                try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [sourceId])
            }
            // With the merge, not after it: as a second write its failure left
            // the merge committed, reported as failed and without an undo.
            if confirmTarget {
                try db.execute(sql: "UPDATE speakers SET isConfirmed = 1 WHERE id = ?", arguments: [targetId])
            }
        }

        // Canonical follows the voice set (apply-anon-identification): merged-in
        // meetings must count right away, not on the next incidental recalc.
        // The merge itself is committed; a recalc failure only logs.
        do {
            return try await recalculateEmbedding(speakerId: targetId)
        } catch {
            Log.error("mergeSpeakers: recalculateEmbedding for \(targetId) failed: \(error)")
            return [:]
        }
    }

    // MARK: - Name a Speaker in a Meeting

    /// The meeting's lines under `oldLabel` (those of `fromSpeakerId` when
    /// given) go to a named record: `existingSpeakerId`, or the one `newName`
    /// finds or creates. The record, its link, the confirmation, the lines and
    /// the cleanup are one transaction — as five writes a failure midway left a
    /// confirmed record linked to the meeting without its lines, and no undo.
    /// Canonicals follow the voice set after the commit; a failed recalc only logs.
    func nameSpeakerInMeeting(
        meetingId: String, oldLabel: String, newName: String,
        existingSpeakerId: String? = nil, fromSpeakerId: String?
    ) async throws {
        let speakerId = try await db.writer.write { db in
            let speaker = try existingSpeakerId.flatMap { try Speaker.fetchOne(db, key: $0) }
                ?? Self.findOrCreate(db, name: newName)
            try MeetingSpeaker(meetingId: meetingId, speakerId: speaker.id, diarizationLabel: oldLabel).save(db)
            try db.execute(sql: "UPDATE speakers SET isConfirmed = 1 WHERE id = ?", arguments: [speaker.id])
            try MeetingRepository.renameSpeakerInMeeting(
                db, meetingId: meetingId, oldLabel: oldLabel, newLabel: newName,
                speakerId: speaker.id, fromSpeakerId: fromSpeakerId
            )
            try Self.cleanupOrphanedMeetingSpeakers(db, meetingId: meetingId)
            return speaker.id
        }
        for id in Set([speakerId, fromSpeakerId].compactMap { $0 }) {
            do {
                try await recalculateEmbedding(speakerId: id)
            } catch {
                Log.error("nameSpeakerInMeeting: recalculateEmbedding for \(id) failed: \(error)")
            }
        }
    }

    // MARK: - Detach Meetings

    /// Take meetings away from a speaker record (apply-anon-identification):
    /// each meeting's segments move to a fresh anonymous record of that meeting
    /// under the next free auto label, the meeting association follows, and the
    /// speaker's canonicals are recalculated. A space whose last voices were
    /// removed by THIS detach loses its canonical instead of freezing; a space
    /// the detach never touched (e.g. an enrollment-only canonical with no
    /// segments) is left alone.
    @discardableResult
    func detachMeetings(speakerId: String, meetingIds: [String]) async throws -> [EmbeddingSpace: RecalcOutcome] {
        guard !meetingIds.isEmpty else { return [:] }
        try await db.writer.write { db in
            let ph = databaseQuestionMarks(count: meetingIds.count)
            // Spaces this detach drains — decided before the moves so an
            // untouched space keeps its canonical afterwards.
            var drained: Set<String> = []
            for space in EmbeddingSpace.allCases {
                let n = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM transcript_segments ts
                    JOIN meetings m ON m.id = ts.meetingId
                    WHERE ts.speakerId = ? AND ts.meetingId IN (\(ph))
                      AND ts.embedding IS NOT NULL AND ts.isExcluded = 0
                      AND \(space.meetingFilterSQL)
                    """, arguments: StatementArguments([speakerId] + meetingIds)) ?? 0
                if n > 0 { drained.insert(space.rawValue) }
            }

            var hues = try Double.fetchAll(db, sql: "SELECT hue FROM speakers WHERE hue IS NOT NULL")
            for meetingId in meetingIds {
                // Detaching says «this is not X here»; a verdict «this is X»
                // would hand the lines back on the next reprocess.
                try db.execute(
                    sql: "DELETE FROM meeting_marks WHERE speakerId = ? AND meetingId = ? AND kind = ?",
                    arguments: [speakerId, meetingId, MarkKind.speaker.rawValue]
                )
                try Self.moveToFreshAnon(db, speakerId: speakerId, meetingId: meetingId, hues: &hues)
            }

            // Orphaned-space cleanup: drained by this detach with nothing left.
            for space in EmbeddingSpace.allCases where drained.contains(space.rawValue) {
                let left = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM transcript_segments ts
                    JOIN meetings m ON m.id = ts.meetingId
                    WHERE ts.speakerId = ?
                      AND ts.embedding IS NOT NULL AND ts.isExcluded = 0
                      AND \(space.meetingFilterSQL)
                    """, arguments: [speakerId]) ?? 0
                if left == 0 {
                    try db.execute(
                        sql: "UPDATE speakers SET \(space.rawValue) = NULL WHERE id = ?",
                        arguments: [speakerId]
                    )
                }
            }
        }

        // Canonical follows the voice set.
        return try await recalculateEmbedding(speakerId: speakerId)
    }

    // MARK: - Delete Speaker

    enum DeleteError: Error, LocalizedError {
        case notFound
        /// The owner record carries mic attribution and the foreign-voice rule.
        case isOwner

        var errorDescription: String? {
            switch self {
            case .notFound: return "speaker not found"
            case .isOwner: return "this speaker is you; mark another speaker as you first"
            }
        }
    }

    /// Delete a speaker record: in every meeting its lines move to a
    /// fresh anonymous record, as detach does; its verdicts go, and the row
    /// with its canonicals is deleted — so it leaves the candidate pool.
    /// Returns the meetings that were touched.
    @discardableResult
    func deleteSpeaker(_ speakerId: String) async throws -> Int {
        try await db.writer.write { db in
            guard let speaker = try Speaker.fetchOne(db, key: speakerId) else { throw DeleteError.notFound }
            guard !speaker.isMe else { throw DeleteError.isOwner }
            let meetingIds = try String.fetchAll(db, sql: """
                SELECT meetingId FROM meeting_speakers WHERE speakerId = ?
                UNION
                SELECT meetingId FROM transcript_segments WHERE speakerId = ?
                """, arguments: [speakerId, speakerId])
            var hues = try Double.fetchAll(db, sql: "SELECT hue FROM speakers WHERE hue IS NOT NULL")
            for meetingId in meetingIds {
                try Self.moveToFreshAnon(db, speakerId: speakerId, meetingId: meetingId, hues: &hues)
            }
            try db.execute(sql: "DELETE FROM meeting_marks WHERE speakerId = ?", arguments: [speakerId])
            try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [speakerId])
            return meetingIds.count
        }
    }

    /// The meeting's lines of `speakerId` move to a fresh anonymous record under
    /// the next free auto label, and the meeting association follows; without
    /// lines only the association goes. Shared by detach and delete.
    private static func moveToFreshAnon(
        _ db: Database, speakerId: String, meetingId: String, hues: inout [Double]
    ) throws {
        let segments = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM transcript_segments
            WHERE speakerId = ? AND meetingId = ?
            """, arguments: [speakerId, meetingId]) ?? 0
        guard segments > 0 else {
            // Nothing to carry — just drop the association.
            try db.execute(
                sql: "DELETE FROM meeting_speakers WHERE speakerId = ? AND meetingId = ?",
                arguments: [speakerId, meetingId]
            )
            return
        }
        // Labels are unique within a meeting: number after the highest
        // speaker_N taken by segment labels or the meeting's records.
        let taken = try String.fetchAll(db, sql: """
            SELECT DISTINCT speakerLabel FROM transcript_segments
            WHERE meetingId = ? AND speakerLabel IS NOT NULL
            UNION
            SELECT s.nameEn FROM meeting_speakers ms
            JOIN speakers s ON s.id = ms.speakerId
            WHERE ms.meetingId = ?
            """, arguments: [meetingId, meetingId])
        let maxN = taken.compactMap { name -> Int? in
            guard name.hasPrefix("speaker_"), let n = Int(name.dropFirst(8)) else { return nil }
            return n
        }.max() ?? 0
        let label = "speaker_\(maxN + 1)"

        let hue = SpeakerHueMath.nextHue(existing: hues)
        hues.append(hue)
        let fresh = Speaker(nameEn: label, hue: hue)
        try fresh.insert(db)

        // Reassignment renames the label too — same as update_segment
        // and merge: the old name was wrong for these lines.
        try db.execute(sql: """
            UPDATE transcript_segments SET speakerId = ?, speakerLabel = ?
            WHERE speakerId = ? AND meetingId = ?
            """, arguments: [fresh.id, label, speakerId, meetingId])
        try db.execute(
            sql: "DELETE FROM meeting_speakers WHERE speakerId = ? AND meetingId = ?",
            arguments: [speakerId, meetingId]
        )
        try MeetingSpeaker(meetingId: meetingId, speakerId: fresh.id, diarizationLabel: label)
            .insert(db)
    }
}
