import Foundation
import GRDB

// MARK: - Projection (pure)

/// The projection rule (design D2): a segment is excluded when at least half
/// of its duration lies under `excluded` state of its own track. Marks apply
/// in creation order, later marks overriding earlier ones where they overlap;
/// the default state of uncovered time is `included`.
///
/// Pure and synchronous so the rule itself is testable without a database.
enum ExclusionProjection {
    /// Fraction of a segment's duration that must be covered by excluded
    /// state for the segment to be hidden.
    static let coverageThreshold = 0.5

    static func isExcluded(
        segmentStart: Double,
        segmentEnd: Double,
        track: SegmentSource,
        marks: [MeetingMark]
    ) -> Bool {
        let duration = segmentEnd - segmentStart
        guard duration > 0 else { return false }
        // Only visibility marks decide; a later `zoomUnmuted` record must not
        // outrank an earlier user exclusion (zoom-unmuted-keeps-mic D2).
        let relevant = marks.filter { $0.track == track && MarkKind.visibility.contains($0.kind) }
        let excludedMeasure = MarkSpans.elementary(segmentStart, segmentEnd, relevant)
            .filter { $0.covering?.kind == .excluded }
            .reduce(0) { $0 + $1.length }
        return excludedMeasure >= coverageThreshold * duration
    }

    /// Ids of segments the rule excludes. Segments without an id are skipped.
    static func excludedSegmentIds(
        segments: [TranscriptSegment],
        marks: [MeetingMark]
    ) -> Set<Int64> {
        guard !marks.isEmpty else { return [] }
        var result: Set<Int64> = []
        for segment in segments {
            guard let id = segment.id else { continue }
            if isExcluded(
                segmentStart: segment.startTime,
                segmentEnd: segment.endTime,
                track: segment.source,
                marks: marks
            ) {
                result.insert(id)
            }
        }
        return result
    }
}

/// Elementary sub-intervals of a segment between every mark boundary inside
/// it, each with the LAST covering mark by creation order — the one partition
/// both exclusion and verdict projections are built on.
enum MarkSpans {
    struct Span {
        let length: Double
        let covering: MeetingMark?
    }

    static func elementary(_ segmentStart: Double, _ segmentEnd: Double, _ marks: [MeetingMark]) -> [Span] {
        let ordered = marks.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return ($0.id ?? 0) < ($1.id ?? 0)
        }
        var bounds: Set<Double> = [segmentStart, segmentEnd]
        for mark in ordered {
            let end = mark.endTime ?? .greatestFiniteMagnitude
            if mark.startTime > segmentStart, mark.startTime < segmentEnd { bounds.insert(mark.startTime) }
            if end > segmentStart, end < segmentEnd { bounds.insert(end) }
        }
        let sorted = bounds.sorted()
        return zip(sorted, sorted.dropFirst()).map { from, to in
            let midpoint = (from + to) / 2
            let covering = ordered.last { mark in
                mark.startTime <= midpoint && midpoint < (mark.endTime ?? .greatestFiniteMagnitude)
            }
            return Span(length: to - from, covering: covering)
        }
    }
}

/// The verdict rule (listen-queue § 4): a segment goes to a verdict's speaker
/// when `speaker` verdicts of its own track cover at least half of it. Where
/// verdicts overlap the later one wins (a later `skipped` gives the stretch to
/// nobody); between several speakers the one with more covered measure wins.
enum VerdictProjection {
    static let coverageThreshold = 0.5

    static func speakerId(
        segmentStart: Double,
        segmentEnd: Double,
        track: SegmentSource,
        verdicts: [MeetingMark]
    ) -> String? {
        let duration = segmentEnd - segmentStart
        guard duration > 0 else { return nil }
        let relevant = verdicts.filter { $0.track == track && MarkKind.verdicts.contains($0.kind) }
        guard !relevant.isEmpty else { return nil }
        var measure: [String: Double] = [:]
        for span in MarkSpans.elementary(segmentStart, segmentEnd, relevant) {
            guard let mark = span.covering, mark.kind == .speaker, let id = mark.speakerId else { continue }
            measure[id, default: 0] += span.length
        }
        guard measure.values.reduce(0, +) >= coverageThreshold * duration else { return nil }
        return measure.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// A verdict takes the track of the lines it was made over, and builds
    /// before the merger kept tracks stamped every line of a two-track meeting
    /// `.merged`. Once such a meeting is reprocessed its lines are mic and
    /// system, and the verdict matched nothing. It goes where the
    /// recorder puts its speaker: the owner on the mic, anyone else on the call
    /// track. A meeting still on merged lines, or on one track, keeps it as is
    /// or on that track.
    static func resolvingMergedTrack(
        _ verdicts: [MeetingMark], segments: [TranscriptSegment], ownerIds: Set<String>
    ) -> [MeetingMark] {
        let tracks = Set(segments.map(\.source))
        guard !tracks.contains(.merged) else { return verdicts }
        return verdicts.map { mark in
            guard mark.track == .merged, mark.kind == .speaker, let id = mark.speakerId else { return mark }
            var resolved = mark
            if tracks.count == 1, let only = tracks.first {
                resolved.track = only
            } else {
                resolved.track = ownerIds.contains(id) ? .mic : .system
            }
            return resolved
        }
    }

    /// Segment id → the speaker its verdicts give it. Segments no verdict
    /// claims are absent.
    static func assignments(segments: [TranscriptSegment], verdicts: [MeetingMark]) -> [Int64: String] {
        guard !verdicts.isEmpty else { return [:] }
        var result: [Int64: String] = [:]
        for segment in segments {
            guard let id = segment.id,
                  let speaker = speakerId(
                      segmentStart: segment.startTime, segmentEnd: segment.endTime,
                      track: segment.source, verdicts: verdicts
                  )
            else { continue }
            result[id] = speaker
        }
        return result
    }
}

// MARK: - Repository

struct MarkRepository {
    /// What a reprojection changed: which segments flipped, and whose
    /// canonical embeddings are now stale and need `recalculateEmbedding`.
    struct ReprojectionResult {
        var changedSegmentIds: Set<Int64> = []
        var affectedSpeakerIds: Set<String> = []
    }

    private let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: CRUD

    /// Every mark of the meeting except speaker verdicts: visibility marks plus
    /// the records (`zoomUnmuted`, dictations) their readers need. Verdicts stay
    /// out so that exclusion projection, the recording button and the foreign
    /// voice rule never see them (listen-queue § 6).
    func marks(for meetingId: String) async throws -> [MeetingMark] {
        try await db.reader.read { db in
            try MeetingMark
                .filter(MeetingMark.Columns.meetingId == meetingId)
                .filter(!MarkKind.verdicts.map(\.rawValue).contains(MeetingMark.Columns.kind))
                .order(MeetingMark.Columns.startTime)
                .fetchAll(db)
        }
    }

    /// The listening decisions of a meeting: `speaker` and `skipped` marks.
    func verdicts(for meetingId: String) async throws -> [MeetingMark] {
        try await db.reader.read { db in
            try MeetingMark
                .filter(MeetingMark.Columns.meetingId == meetingId)
                .filter(MarkKind.verdicts.map(\.rawValue).contains(MeetingMark.Columns.kind))
                .order(MeetingMark.Columns.startTime)
                .fetchAll(db)
        }
    }

    enum MarkError: Error {
        /// A `.speaker` verdict without a speaker, or a speaker on any other kind.
        case verdictSpeakerMismatch
    }

    @discardableResult
    func add(_ mark: MeetingMark) async throws -> MeetingMark {
        // No CHECK constraint via ALTER TABLE, so the API holds «speaker ⇔ speakerId».
        guard (mark.kind == .speaker) == (mark.speakerId != nil) else { throw MarkError.verdictSpeakerMismatch }
        var inserted = mark
        inserted = try await db.writer.write { db in
            var m = mark
            try m.insert(db)
            return m
        }
        Log.info("Mark added: \(inserted.kind.rawValue) [\(format(inserted.startTime))–\(inserted.endTime.map(format) ?? "open")] track=\(inserted.track.rawValue) source=\(inserted.source.rawValue) meeting=\(mark.meetingId)")
        return inserted
    }

    /// Drops the marks the app derived itself (foreign voices hidden by the
    /// default, `ForeignVoicePolicy`). They are re-derived on every processing
    /// pass, so they must not pile up; the user's own marks and the
    /// recording-time button intervals are left alone. So are the
    /// `ownerLikely` windows: mic attribution derives those, earlier in the
    /// same pass, and the policy reads them right after this.
    func deleteAuto(meetingId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM meeting_marks WHERE meetingId = ? AND source = ? AND kind != ?",
                arguments: [meetingId, MarkSource.auto.rawValue, MarkKind.ownerLikely.rawValue]
            )
        }
    }

    /// Replaces the meeting's `ownerLikely` windows. They describe
    /// the segments of one processing pass, so the previous pass's go first —
    /// also when the new pass found none.
    func replaceOwnerLikely(meetingId: String, with intervals: [(start: Double, end: Double)]) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM meeting_marks WHERE meetingId = ? AND kind = ?",
                arguments: [meetingId, MarkKind.ownerLikely.rawValue]
            )
            for interval in intervals {
                var mark = MeetingMark(
                    meetingId: meetingId, startTime: interval.start, endTime: interval.end,
                    track: .mic, kind: .ownerLikely, source: .auto
                )
                try mark.insert(db)
            }
        }
        if !intervals.isEmpty {
            Log.info("Owner-likely mic windows for \(meetingId): \(intervals.count)")
        }
    }

    /// Removes one mark. Returns false when no such mark belongs to the meeting.
    @discardableResult
    func delete(id: Int64, meetingId: String) async throws -> Bool {
        let deleted = try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM meeting_marks WHERE id = ? AND meetingId = ?",
                arguments: [id, meetingId]
            )
            return db.changesCount > 0
        }
        if deleted { Log.info("Mark \(id) removed from meeting \(meetingId)") }
        return deleted
    }

    // MARK: Whole track

    /// An excluded mark over all of `track`, `end` being the meeting's length:
    /// what «Exclude mic track» lays. An open interval reaches the end too.
    static func hidesWholeTrack(_ mark: MeetingMark, _ track: SegmentSource, end: Double) -> Bool {
        mark.kind == .excluded && mark.track == track && mark.startTime <= 0 && (mark.endTime ?? .infinity) >= end
    }

    /// One mark over the whole track, not one per line; the other track is left alone.
    func excludeWholeTrack(meetingId: String, track: SegmentSource, end: Double) async throws {
        try await add(MeetingMark(meetingId: meetingId, startTime: 0, endTime: end, track: track, kind: .excluded))
        try await reprojectAndRecalc(meetingId: meetingId)
    }

    /// Takes the whole-track marks away: the lines are back to what the other marks say.
    func restoreWholeTrack(meetingId: String, track: SegmentSource, end: Double) async throws {
        for mark in try await marks(for: meetingId) where Self.hidesWholeTrack(mark, track, end: end) {
            if let id = mark.id { try await delete(id: id, meetingId: meetingId) }
        }
        try await reprojectAndRecalc(meetingId: meetingId)
    }

    // MARK: Recording-time button interval (D6)

    /// The still-open button interval of a meeting, if any.
    func openButtonMark(meetingId: String) async throws -> MeetingMark? {
        try await db.reader.read { db in
            try MeetingMark
                .filter(MeetingMark.Columns.meetingId == meetingId)
                .filter(Column("source") == MarkSource.button.rawValue)
                .filter(MeetingMark.Columns.endTime == nil)
                .fetchOne(db)
        }
    }

    /// Closes every open button interval at the given time. Returns how many
    /// intervals were closed — stop-of-recording calls this unconditionally.
    @discardableResult
    func closeOpenButtonMarks(meetingId: String, at time: Double) async throws -> Int {
        let closed = try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE meeting_marks SET endTime = MAX(?, startTime)
                    WHERE meetingId = ? AND source = ? AND endTime IS NULL
                    """,
                arguments: [time, meetingId, MarkSource.button.rawValue]
            )
            return db.changesCount
        }
        if closed > 0 {
            Log.info("Closed \(closed) open button mark(s) at \(format(time)) for meeting \(meetingId)")
        }
        return closed
    }

    // MARK: Projection

    /// Recomputes the `isExcluded` cache of every segment of the meeting from
    /// the marks table (design D1/D2). Returns which segments flipped and
    /// which speakers' canonicals are now stale.
    @discardableResult
    func reproject(meetingId: String) async throws -> ReprojectionResult {
        let marks = try await marks(for: meetingId)
        return try await db.writer.write { db in
            let segments = try TranscriptSegment
                .filter(TranscriptSegment.Columns.meetingId == meetingId)
                .fetchAll(db)
            let excluded = ExclusionProjection.excludedSegmentIds(segments: segments, marks: marks)

            var result = ReprojectionResult()
            for segment in segments {
                guard let id = segment.id else { continue }
                let shouldExclude = excluded.contains(id)
                guard segment.isExcluded != shouldExclude else { continue }
                try db.execute(
                    sql: "UPDATE transcript_segments SET isExcluded = ? WHERE id = ?",
                    arguments: [shouldExclude, id]
                )
                result.changedSegmentIds.insert(id)
                if let speakerId = segment.speakerId {
                    result.affectedSpeakerIds.insert(speakerId)
                }
            }
            if !result.changedSegmentIds.isEmpty {
                Log.info("Reprojected exclusions for meeting \(meetingId): \(result.changedSegmentIds.count) segment(s) flipped, \(excluded.count) excluded total")
            }
            return result
        }
    }

    /// Reprojection plus the embedding hygiene it implies (design D5): every
    /// speaker whose segments flipped gets their canonical recalculated, so
    /// the cascade window between a mark edit and the next meeting's
    /// processing stays closed. Callers on the UI side follow up with a
    /// drift-monitor refresh.
    @discardableResult
    func reprojectAndRecalc(meetingId: String) async throws -> ReprojectionResult {
        let result = try await reproject(meetingId: meetingId)
        guard !result.affectedSpeakerIds.isEmpty else { return result }
        let speakerRepo = SpeakerRepository(db: db)
        for speakerId in result.affectedSpeakerIds.sorted() {
            try await speakerRepo.recalculateEmbedding(speakerId: speakerId, config: .automatic)
        }
        Log.info("Recalculated canonicals for \(result.affectedSpeakerIds.count) speaker(s) after mark change in meeting \(meetingId)")
        return result
    }

    // MARK: Verdicts (listen-queue § 4)

    /// What re-applying a meeting's verdicts did, for the log line and tests.
    struct VerdictApplication: Equatable {
        var marks = 0
        var segments = 0
        var seconds = 0.0
        /// Segments the verdicts took from whoever the pipeline gave them to.
        var overrode = 0
        var overrodeSeconds = 0.0
        /// The part of `overrode` the pipeline had given to a confirmed speaker.
        var fromConfirmed = 0
        var fromConfirmedSeconds = 0.0
        var matchedNothing = 0
        var affectedSpeakerIds: Set<String> = []
    }

    /// Re-applies the `speaker` verdicts of a meeting to its current segments:
    /// moves the segments, keeps `meeting_speakers` true, drops the unconfirmed
    /// rows left without segments and recalculates whoever gained or lost.
    /// Runs after every processing pass, so a reprocess cannot undo a verdict.
    @discardableResult
    func applyVerdicts(meetingId: String) async throws -> VerdictApplication {
        let speakerMarks = try await verdicts(for: meetingId).filter { $0.kind == .speaker }
        var result = VerdictApplication(marks: speakerMarks.count)
        guard !speakerMarks.isEmpty else { return result }

        let meetingRepo = MeetingRepository(db: db)
        let speakerRepo = SpeakerRepository(db: db)
        let segments = try await meetingRepo.segments(for: meetingId)
        let ownerIds = try await db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM speakers WHERE isMe = 1")
        }
        let verdicts = VerdictProjection.resolvingMergedTrack(
            try await verdicts(for: meetingId), segments: segments, ownerIds: Set(ownerIds)
        )
        let assignments = VerdictProjection.assignments(segments: segments, verdicts: verdicts)

        let involved = Set(assignments.values).union(segments.compactMap(\.speakerId))
        let speakers: [String: Speaker] = try await db.reader.read { db in
            try Speaker.filter(keys: Array(involved)).fetchAll(db)
        }.reduce(into: [:]) { $0[$1.id] = $1 }

        var moves: [String: [Int64]] = [:]
        for segment in segments {
            guard let id = segment.id, let target = assignments[id] else { continue }
            let length = segment.endTime - segment.startTime
            result.segments += 1
            result.seconds += length
            guard segment.speakerId != target else { continue }
            moves[target, default: []].append(id)
            result.overrode += 1
            result.overrodeSeconds += length
            if let previous = segment.speakerId {
                result.affectedSpeakerIds.insert(previous)
                if let owner = speakers[previous], owner.isConfirmed || owner.isMe {
                    result.fromConfirmed += 1
                    result.fromConfirmedSeconds += length
                }
            }
        }
        result.matchedNothing = verdicts.filter { $0.kind == .speaker }.filter { mark in
            !segments.contains { segment in
                guard let id = segment.id, assignments[id] == mark.speakerId, segment.source == mark.track else { return false }
                return segment.startTime < (mark.endTime ?? .greatestFiniteMagnitude) && segment.endTime > mark.startTime
            }
        }.count

        for (target, ids) in moves.sorted(by: { $0.key < $1.key }) {
            guard let speaker = speakers[target] else { continue }
            try await meetingRepo.updateSegmentsSpeaker(
                ids: ids, meetingId: meetingId, speakerId: target, speakerLabel: speaker.displayName
            )
            result.affectedSpeakerIds.insert(target)
        }
        if !moves.isEmpty {
            // Links are already reconciled by the moves; only unconfirmed rows
            // left with nothing go — a named person who lost every line stays.
            try await speakerRepo.cleanupOrphanedSpeakers()
            for speakerId in result.affectedSpeakerIds.sorted() {
                // Anonymous donors left with nothing are gone after the cleanup.
                guard try await speakerRepo.find(speakerId) != nil else { continue }
                try await speakerRepo.recalculateEmbedding(speakerId: speakerId, config: .automatic)
            }
        }

        Log.info(String(
            format: "Verdicts: %d mark(s) → %d segment(s) (%.1fs); overrode pipeline on %d (%.1fs), of them %d (%.1fs) from a confirmed speaker; %d mark(s) matched nothing — meeting %@",
            result.marks, result.segments, result.seconds, result.overrode, result.overrodeSeconds,
            result.fromConfirmed, result.fromConfirmedSeconds, result.matchedNothing, meetingId
        ))
        return result
    }

    private func format(_ time: Double) -> String {
        String(format: "%.1fs", time)
    }
}
