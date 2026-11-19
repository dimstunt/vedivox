import FluidAudio
import Foundation

/// Stage 2.5 of the offline diarization pipeline: per-window rescue
/// of speech that within-meeting clustering merged into the wrong cluster.
///
/// Stage 2 (`SpeakerMatcher`) resolves whole clusters; when the offline
/// diarizer under-clusters (8 speakers → 5 clusters on the M5 fixture), the
/// minority speakers inside a merged cluster are unreachable for it. This
/// post-pass inspects the chunk-level WeSpeaker embeddings
/// (`DiarizationResult.chunkEmbeddings` — per ~2-10s window, NOT the
/// per-segment `embedding`, which is just a copy of the cluster centroid) and
/// moves windows that are confidently closer to another enrolled speaker's
/// canonical than to their cluster's owner.
///
/// Thresholds come from the stage-0 separability study plus the seeded bench
/// sweep (the private fixtures, M1-M5 fixtures):
/// - True speakers score 0.63-0.79 against their migrated canonical; pool
///   lookalikes on a foreign voice stay below ~0.55.
/// - When the cluster has no enrolled owner, the window is compared with the
///   cluster's own centroid instead (guard-rescue-and-v2-canon): an unnamed
///   regular's voice sits closer to its own cluster than to any lookalike
///   canonical, so margin keeps it home. Before that `accept` was the only
///   guard, and ambiguous clusters of one weekly meeting were torn apart into lookalike
///   canonicals, which then fed on them. Earlier finding still holds: at
///   accept 0.45-0.50 a non-enrolled owner (Лука, M2) lost up to 300s.
/// - Bench sweep (cross_meeting_seeded): 0.55-0.60/0.05 → M5 conf 55.2s with
///   ~8s of boundary over-rescue; 0.65/0.10 → 52.5s, both lost speakers
///   still recovered as their own identities, M1-M4
///   byte-identical. True targets carry 0.3-0.4 margin headroom, so the
///   tightest equal-best setting wins.
struct SegmentRescue {

    struct Config {
        /// Window must score at least this against the target canonical.
        var acceptThreshold: Float
        /// `sim(target) - sim(cluster owner)` must exceed this. Without an
        /// enrolled owner the cluster's own centroid stands in for it.
        var marginThreshold: Float
        /// Windows shorter than this are too unreliable for WeSpeaker vectors.
        var minWindowSeconds: Double
        /// Fraction of a transcript segment that must be covered by moved
        /// windows of one target before the segment is relabeled.
        var minSegmentCoverage: Double
        /// Enrolled speakers with fewer segments are excluded as rescue targets
        /// (same rationale as `SpeakerMatcher.Config.minSegmentsForCanonical`).
        var minSegmentsForCanonical: Int
        /// stage2-dead-zone: a cluster without an enrolled owner and with less
        /// speech than this gives away no windows — it decides no name, whole
        /// or in pieces. Clusters that exist only among the windows count as 0.
        var minOwnerlessClusterSeconds: Double = 10
        /// stage2-dead-zone: windows of an ownerless cluster that end within
        /// this many seconds of the track end stay put. The last windows run
        /// past the audio (padding, fade-out) and land on outlier canonicals:
        /// every recording-tail move to one such outlier profile on 2026-11-01.
        var tailSeconds: Double = 5

        static let `default` = Config(
            acceptThreshold: 0.65,
            marginThreshold: 0.10,
            minWindowSeconds: 2.0,
            minSegmentCoverage: 0.5,
            minSegmentsForCanonical: 5
        )

        /// Bench sweep knobs (TEST_RUNNER_VEDIVOX_RESCUE_*): accept/margin floats,
        /// VEDIVOX_RESCUE_DISABLED=1 turns the pass off entirely.
        static func fromEnvironment() -> Config? {
            let env = ProcessInfo.processInfo.environment
            if env["VEDIVOX_RESCUE_DISABLED"] == "1" { return nil }
            var config = Config.default
            if let raw = env["VEDIVOX_RESCUE_ACCEPT"], let v = Float(raw) {
                config.acceptThreshold = v
            }
            if let raw = env["VEDIVOX_RESCUE_MARGIN"], let v = Float(raw) {
                config.marginThreshold = v
            }
            return config
        }
    }

    /// One chunk window the pass decided to reattribute.
    struct Move {
        let start: Double
        let end: Double
        let fromCluster: String
        let toSpeakerId: String
        let toDisplayName: String
        let confidence: Float
        /// The window's own WeSpeaker vector. A relabeled segment gets the
        /// overlap-weighted mean of its target's windows (segment-own-voice § 3),
        /// so canonical recalc averages the moved voice, not the old cluster
        /// centroid.
        let embedding: [Float]
    }

    let config: Config

    /// Read-only tap on the chunk windows, for the VedivoxBench stage-2 dump
    /// (VEDIVOX_BENCH_STAGE2_DUMP). Never set in the app.
    nonisolated(unsafe) static var chunkProbe: (([ChunkEmbedding]) -> Void)?

    init(config: Config = .default) {
        self.config = config
    }

    /// Decide which chunk windows should move.
    /// - clusterOwners: FluidAudio cluster id ("S1") → enrolled speakerId it
    ///   resolved to in Stage 2 (absent = cluster stayed an unknown speaker_N).
    /// - clusterCentroids: cluster id → its diarizer centroid; the owner
    ///   reference for clusters without an enrolled owner.
    func planMoves(
        chunks: [ChunkEmbedding],
        clusterOwners: [String: String],
        pool: [SpeakerMatcher.Candidate],
        clusterCentroids: [String: [Float]] = [:],
        clusterMass: [String: Double]? = nil
    ) -> [Move] {
        Self.chunkProbe?(chunks)
        let targets = pool.filter { $0.segmentCount >= config.minSegmentsForCanonical }
        guard !targets.isEmpty else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: targets.map { ($0.speakerId, $0) })
        // Ownerless guards need the cluster masses; without them (unit tests,
        // callers that predate stage2-dead-zone) they stay off.
        let trackEnd = Double(chunks.map(\.endTimeSeconds).max() ?? 0)
        var skippedMicro = 0
        var skippedTail = 0

        var moves: [Move] = []
        for chunk in chunks {
            let dur = chunk.endTimeSeconds - chunk.startTimeSeconds
            guard dur >= config.minWindowSeconds, !chunk.embedding256.isEmpty else { continue }

            let ownerId = clusterOwners[chunk.speakerId]
            if ownerId == nil, let clusterMass {
                if clusterMass[chunk.speakerId, default: 0] < config.minOwnerlessClusterSeconds {
                    skippedMicro += 1
                    continue
                }
                if Double(chunk.endTimeSeconds) > trackEnd - config.tailSeconds {
                    skippedTail += 1
                    continue
                }
            }
            let ownerReference = ownerId.flatMap { byId[$0]?.canonical }
                ?? clusterCentroids[chunk.speakerId].flatMap { $0.count == chunk.embedding256.count ? $0 : nil }
            let ownerSim = ownerReference.map { cosineSimilarity(chunk.embedding256, $0) } ?? 0

            guard let best = targets
                .map({ (candidate: $0, sim: cosineSimilarity(chunk.embedding256, $0.canonical)) })
                .max(by: { $0.sim < $1.sim })
            else { continue }

            guard best.candidate.speakerId != ownerId,
                  best.sim >= config.acceptThreshold,
                  best.sim - ownerSim >= config.marginThreshold
            else { continue }

            moves.append(Move(
                start: Double(chunk.startTimeSeconds),
                end: Double(chunk.endTimeSeconds),
                fromCluster: chunk.speakerId,
                toSpeakerId: best.candidate.speakerId,
                toDisplayName: best.candidate.displayName,
                confidence: best.sim,
                embedding: chunk.embedding256
            ))
        }
        if clusterMass != nil {
            Log.info("Stage-2.5 rescue: skipped windows of ownerless clusters — \(skippedMicro) micro (<\(Int(config.minOwnerlessClusterSeconds))s), \(skippedTail) at the track tail (last \(Int(config.tailSeconds))s)")
        }
        return moves
    }

    /// Relabel transcript segments whose time is mostly covered by moves to a
    /// single target. Returns the rewritten segments, the moved speech seconds,
    /// and label→speakerId entries for the targets so the caller can link them.
    /// `boundLabels`: labels already bound to records in this meeting (Stage 2).
    /// A target keeps its label there; a different record with a taken name —
    /// bound, or a fresh `speaker_N` in these segments — gets a distinct one,
    /// so a moved line never merges two records (stage2-out-of-pool).
    func apply(
        moves: [Move],
        to segments: [TranscriptSegment],
        boundLabels: [String: String] = [:]
    ) -> (segments: [TranscriptSegment], movedSeconds: Double, labelToDbId: [String: String]) {
        guard !moves.isEmpty else { return (segments, 0, [:]) }

        var out = segments
        var movedSeconds = 0.0
        var labelToDbId: [String: String] = [:]
        var book = SpeakerLabelBook(
            bindings: boundLabels,
            reserved: Set(segments.compactMap(\.speakerLabel)).subtracting(boundLabels.keys)
        )

        for i in out.indices {
            let seg = out[i]
            let dur = seg.endTime - seg.startTime
            guard dur > 0 else { continue }

            // Coverage and best window per target.
            var coverage: [String: Double] = [:]
            var bestWindow: [String: Move] = [:]
            var bestOverlap: [String: Double] = [:]
            for move in moves {
                let overlap = max(0, min(seg.endTime, move.end) - max(seg.startTime, move.start))
                guard overlap > 0 else { continue }
                coverage[move.toSpeakerId, default: 0] += overlap
                if overlap > bestOverlap[move.toSpeakerId, default: 0] {
                    bestOverlap[move.toSpeakerId] = overlap
                    bestWindow[move.toSpeakerId] = move
                }
            }
            guard let (targetId, covered) = coverage.max(by: { $0.value < $1.value }),
                  covered / dur >= config.minSegmentCoverage,
                  let move = bestWindow[targetId]
            else { continue }
            let label = book.label(for: move.toDisplayName, speakerId: targetId)
            guard seg.speakerLabel != label else { continue }

            out[i].speakerLabel = label
            out[i].speakerId = nil // relinked from the label by the caller
            let targetWindows = moves.filter { $0.toSpeakerId == targetId }
                .map { SegmentVoice.Timed(start: $0.start, end: $0.end, vector: $0.embedding) }
            out[i].embedding = SegmentVoice.vector(start: seg.startTime, end: seg.endTime, from: targetWindows)
                .map { Speaker.encodeEmbedding($0.vector) }
            movedSeconds += dur
            labelToDbId[label] = targetId
        }
        return (out, movedSeconds, labelToDbId)
    }
}
