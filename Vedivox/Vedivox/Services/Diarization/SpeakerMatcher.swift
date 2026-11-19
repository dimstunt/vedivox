import Foundation

/// Stage 2 of the two-stage diarization pipeline.
///
/// Stage 1 (FluidAudio's `DiarizerManager` with no enrollment) produces `K`
/// anonymous within-meeting clusters and a per-cluster aggregate embedding.
/// Stage 2 (this type) matches each cluster centroid against the database of
/// confirmed enrolled speakers using a strict accept threshold + top-1/top-2
/// margin guard, with low-data canonicals filtered out of the matching pool.
///
/// Why two stages: per-segment matching during diarization (the old approach)
/// conflated within-meeting clustering with cross-meeting identification.
/// Aggregating into cluster centroids gives an order-of-magnitude SNR boost,
/// which is what makes a strict threshold viable.
///
/// Empirical context: an audit on 2026-05-06—07 found 34 of 64 enrolled
/// speakers had canonical embeddings merged with another enrolled (sim > 0.6)
/// because per-segment matching with a loose threshold (cosine distance < 0.84,
/// i.e. similarity > 0.16) routinely picked the wrong identity. With cluster
/// centroids the same data shows margins 0.10–0.60 to the correct speaker —
/// huge headroom for strict thresholds.
struct SpeakerMatcher {

    /// Tunable thresholds for the matcher.
    struct Config {
        /// Top-1 cosine similarity must exceed this for a match.
        var acceptThreshold: Float
        /// `(top1 - top2)` must exceed this — defends against ambiguity when
        /// a cluster sits between two acoustically close enrolled speakers.
        var marginThreshold: Float
        /// Enrolled speakers with fewer segments than this are filtered out of
        /// the matching pool. Their canonicals are too noisy and become
        /// magnets for unrelated voices (a 3-segment
        /// canonical scored sim 0.70 against a different person's voice).
        var minSegmentsForCanonical: Int
        /// A cluster with less speech than this never decides an identity on
        /// its own (stage2-dead-zone): it abstains as `tooShort` and the
        /// labeler's micro-cluster rules fold it into a resolved cluster or
        /// UNKNOWN. 0 disables the rule.
        var minIdentityMassSeconds: Double = 0
        /// Mic track (stage2-mic-owner): when the top candidate is this record
        /// (the isMe owner) the owner thresholds below apply and the mass rule
        /// does not; every other candidate is held to the general rules.
        var ownerSpeakerId: String?
        var ownerAcceptThreshold: Float = 0.55
        var ownerMarginThreshold: Float = 0.05
        /// Mic track: an unnamed cluster whose best candidate is the
        /// owner at this similarity or above is not a stranger's — see
        /// `ownerLikelyClusters`. Not an accept threshold: no name is given.
        /// 0.50 is the dead-zone hint's floor; on the live DB (2026-11-09) the
        /// closest named stranger on the mic scored 0.455 against the owner.
        var ownerLikelyFloor: Float = 0.50

        /// System track and imports (stage2-dead-zone): a name only with a
        /// margin to spare. Bench: own clusters ≥ 10 s sit at 0.78+, wrong
        /// names at 0.56–0.70; live DB at margin 0.10 — newcomers misnamed
        /// 35.3% → 6.9%, own voices named 94.0% → 89.8%.
        static let `default` = Config(
            acceptThreshold: 0.70,
            marginThreshold: 0.10,
            minSegmentsForCanonical: 5,
            minIdentityMassSeconds: 10
        )

        /// Mic track: the owner keeps the old thresholds (0.55 / 0.05, no mass
        /// rule) — his built-in-mic meeting voices reach only ~0.69 (LOO p5) to
        /// his canonical. Anyone else on the mic needs the system-track margin:
        /// the old thresholds for every candidate let one wide outlier
        /// canonical take the owner's own speech and five guests (2026-11-01).
        static func mic(ownerId: String) -> Config {
            var config = Config.default
            config.ownerSpeakerId = ownerId
            return config
        }
    }

    /// One enrolled speaker eligible for matching.
    struct Candidate {
        let speakerId: String
        let displayName: String
        let canonical: [Float]
        let segmentCount: Int
    }

    /// Outcome of matching one cluster.
    enum Resolution: Equatable {
        /// Confident match. Use this enrolled speaker's UUID and display name.
        case matched(speakerId: String, displayName: String, confidence: Float)
        /// Per-segment split — the cluster contains multiple
        /// distinct enrolled speakers (or one + an unknown tail). Each
        /// `SubGroup` carries the segment keys it owns, so the caller can
        /// relabel segment-by-segment instead of cluster-by-cluster.
        case splitMatches([SubClusterSplitter.SubGroup])
        /// No confident match. Caller should treat the cluster as a new
        /// `speaker_N`. The reason is captured for logging.
        case unmatched(reason: AbstainReason)
    }

    /// Why a cluster was not matched. Surfaced for logging and possible UI hints.
    enum AbstainReason: Equatable {
        /// All candidates scored below `acceptThreshold`.
        case lowSimilarity(topSim: Float, topName: String?)
        /// Top-1 was high enough but top-2 was too close — ambiguous identity.
        case ambiguousMargin(topSim: Float, margin: Float, topName: String, runnerUpName: String)
        /// No candidates after filtering (e.g. empty enrollment, or all below
        /// `minSegmentsForCanonical`).
        case emptyPool
        /// Less speech than `minIdentityMassSeconds`: too little to decide an
        /// identity alone, whatever the score (stage2-dead-zone).
        case tooShort(massSeconds: Double, topSim: Float, topName: String?)
    }

    let config: Config

    /// Read-only tap on every Stage-2 input (clusters + pool), for the VedivoxBench
    /// stage-2 dump (VEDIVOX_BENCH_STAGE2_DUMP). Never set in the app.
    nonisolated(unsafe) static var inputProbe: (([String: [DiarizationService.DiarizationSegment]], [Candidate]) -> Void)?

    init(config: Config = .default) {
        self.config = config
    }

    /// Match a single cluster centroid against the pool. Pool is filtered
    /// internally by `minSegmentsForCanonical`.
    func match(clusterCentroid centroid: [Float], pool: [Candidate]) -> Resolution {
        let filtered = pool.filter { $0.segmentCount >= config.minSegmentsForCanonical }
        guard !filtered.isEmpty else {
            return .unmatched(reason: .emptyPool)
        }

        let scored = filtered
            .map { (candidate: $0, sim: cosineSimilarity(centroid, $0.canonical)) }
            .sorted { $0.sim > $1.sim }

        let top = scored[0]
        let runnerUp = scored.count > 1 ? scored[1] : nil

        let isOwner = config.ownerSpeakerId != nil && top.candidate.speakerId == config.ownerSpeakerId
        let accept = isOwner ? config.ownerAcceptThreshold : config.acceptThreshold
        let marginFloor = isOwner ? config.ownerMarginThreshold : config.marginThreshold

        if top.sim < accept {
            return .unmatched(reason: .lowSimilarity(topSim: top.sim, topName: top.candidate.displayName))
        }

        if let runnerUp {
            let margin = top.sim - runnerUp.sim
            if margin < marginFloor {
                return .unmatched(reason: .ambiguousMargin(
                    topSim: top.sim,
                    margin: margin,
                    topName: top.candidate.displayName,
                    runnerUpName: runnerUp.candidate.displayName
                ))
            }
        }

        return .matched(
            speakerId: top.candidate.speakerId,
            displayName: top.candidate.displayName,
            confidence: top.sim
        )
    }

    /// Match every cluster in `clusterCentroids`, keyed by FluidAudio's
    /// internal cluster id (e.g. "1", "2"). The same `pool` is used for all.
    func matchAll(
        clusterCentroids: [String: [Float]],
        pool: [Candidate]
    ) -> [String: Resolution] {
        var out: [String: Resolution] = [:]
        for (clusterId, centroid) in clusterCentroids {
            out[clusterId] = match(clusterCentroid: centroid, pool: pool)
        }
        return out
    }

    /// Resolve every cluster using per-segment canonical affinity first
    /// falling through to cluster-centroid matching when the
    /// per-segment voting is inconclusive. This is the production entrypoint:
    /// it recovers the over-merge case (single FluidAudio cluster covering
    /// multiple acoustically close enrolled speakers) without re-introducing
    /// the anchored-clustering poisoning vector that removed.
    ///
    /// `clusterToSegments` is keyed by FluidAudio cluster id; values are the
    /// per-cluster segments with their embeddings.
    func matchAllWithAffinity(
        clusterToSegments: [String: [DiarizationService.DiarizationSegment]],
        pool: [Candidate],
        splitterConfig: SubClusterSplitter.Config? = nil
    ) -> [String: Resolution] {
        Self.inputProbe?(clusterToSegments, pool)
        let splitter = SubClusterSplitter(config: splitterConfig ?? Self.splitterConfig(for: config))
        // Until the splitter is re-tuned on own vectors, Stage 2 sees the
        // centroid copies it was calibrated on (segment-own-voice § 4).
        let input = splitter.config.useOwnVectors ? clusterToSegments : clusterToSegments.mapValues { segments in
            segments.map { seg in
                seg.clusterEmbedding.map {
                    DiarizationService.DiarizationSegment(start: seg.start, end: seg.end, speaker: seg.speaker, embedding: $0)
                } ?? seg
            }
        }
        var out: [String: Resolution] = [:]
        for (clusterId, segments) in input {
            let mass = segments.reduce(0.0) { $0 + max(0, Double($1.end - $1.start)) }
            if mass < config.minIdentityMassSeconds {
                // Score it anyway so the log shows what it would have been.
                let centroid = Self.naiveMean(segments.compactMap(\.embedding))
                switch match(clusterCentroid: centroid, pool: pool) {
                case .unmatched(.emptyPool):
                    out[clusterId] = .unmatched(reason: .emptyPool)
                case .matched(let id, let name, let sim) where id == config.ownerSpeakerId:
                    out[clusterId] = .matched(speakerId: id, displayName: name, confidence: sim)
                case .matched(_, let name, let sim):
                    out[clusterId] = .unmatched(reason: .tooShort(massSeconds: mass, topSim: sim, topName: name))
                case .unmatched(.lowSimilarity(let sim, let name)), .unmatched(.tooShort(_, let sim, let name)):
                    out[clusterId] = .unmatched(reason: .tooShort(massSeconds: mass, topSim: sim, topName: name))
                case .unmatched(.ambiguousMargin(let sim, _, let name, _)):
                    out[clusterId] = .unmatched(reason: .tooShort(massSeconds: mass, topSim: sim, topName: name))
                case .splitMatches:
                    out[clusterId] = .unmatched(reason: .tooShort(massSeconds: mass, topSim: 0, topName: nil))
                }
                continue
            }
            switch splitter.resolve(clusterSegments: segments, pool: pool) {
            case .singleMatch(let speakerId, let displayName, let confidence):
                out[clusterId] = .matched(
                    speakerId: speakerId,
                    displayName: displayName,
                    confidence: confidence
                )
            case .splitMatches(let groups):
                out[clusterId] = .splitMatches(groups)
            case .fallBack:
                let centroid = Self.naiveMean(segments.compactMap(\.embedding))
                out[clusterId] = match(clusterCentroid: centroid, pool: pool)
            }
        }
        return out
    }

    /// Mic track: clusters `results` left without a name although
    /// their best candidate is the owner at `ownerLikelyFloor` or above — a
    /// near miss of his threshold, a thin margin or too little speech. Nothing
    /// is matched here: the cluster keeps the label it got, the foreign-voice
    /// rule just must not take it for somebody else's speech. Empty without an
    /// owner in the config (system track, imports).
    func ownerLikelyClusters(
        clusterToSegments: [String: [DiarizationService.DiarizationSegment]],
        pool: [Candidate],
        results: [String: Resolution]
    ) -> Set<String> {
        guard let ownerId = config.ownerSpeakerId else { return [] }
        let eligible = pool.filter { $0.segmentCount >= config.minSegmentsForCanonical }
        return Set(clusterToSegments.compactMap { clusterId, segments -> String? in
            guard case .unmatched = results[clusterId] else { return nil }
            let centroid = Self.naiveMean(segments.compactMap(\.embedding))
            let best = eligible
                .filter { $0.canonical.count == centroid.count }
                .map { (id: $0.speakerId, sim: cosineSimilarity(centroid, $0.canonical)) }
                .max { $0.sim < $1.sim }
            guard let best, best.id == ownerId, best.sim >= config.ownerLikelyFloor else { return nil }
            return clusterId
        })
    }

    /// The splitter decides before the matcher on the offline path (every
    /// segment carries the centroid, so its vote is the centroid's): its
    /// thresholds must be the matcher's or `singleMatch` bypasses them.
    static func splitterConfig(for config: Config) -> SubClusterSplitter.Config {
        var split = SubClusterSplitter.Config.default
        split.perSegmentAcceptThreshold = config.acceptThreshold
        split.perSegmentMarginThreshold = config.marginThreshold
        split.fallbackCentroidAcceptThreshold = max(split.fallbackCentroidAcceptThreshold, config.acceptThreshold)
        split.fallbackCentroidMarginThreshold = max(split.fallbackCentroidMarginThreshold, config.marginThreshold)
        // Bench sweep only (segment-own-voice 5.1): per-segment vote thresholds.
        let env = ProcessInfo.processInfo.environment
        if let v = env["VEDIVOX_SPLITTER_ACCEPT"].flatMap(Float.init) { split.perSegmentAcceptThreshold = v }
        if let v = env["VEDIVOX_SPLITTER_MARGIN"].flatMap(Float.init) { split.perSegmentMarginThreshold = v }
        return split
    }

    /// Centroid used when falling through to cluster-centroid matching. Empty
    /// input yields an empty vector, which the matcher then handles as a
    /// `lowSimilarity` abstain via `cosineSimilarity` returning 0.
    private static func naiveMean(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        for emb in embeddings where emb.count == dim {
            for i in 0 ..< dim { sum[i] += emb[i] }
        }
        let n = Float(embeddings.count)
        guard n > 0 else { return sum }
        var out = sum.map { $0 / n }
        let norm = (out.reduce(0) { $0 + $1 * $1 }).squareRoot()
        if norm > 0 {
            out = out.map { $0 / norm }
        }
        return out
    }
}

// MARK: - Cosine similarity

/// Cosine similarity between two equal-length float vectors. Returns 0 if either
/// vector is empty or has zero magnitude.
///
/// Kept here (rather than a shared math module) because it's the only piece of
/// vector arithmetic the diarization pipeline needs and inlining keeps the
/// dependency surface small. The test target reimplements it locally so tests
/// aren't coupled to the production type.
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "vector dimension mismatch \(a.count) vs \(b.count)")
    guard !a.isEmpty else { return 0 }
    var dot: Float = 0
    var na: Float = 0
    var nb: Float = 0
    for i in 0 ..< a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    let denom = (na * nb).squareRoot()
    guard denom > 0 else { return 0 }
    return dot / denom
}
