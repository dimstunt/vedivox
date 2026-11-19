import Foundation

/// Per-segment canonical-affinity classifier. Recovers the
/// over-merge fallout of when FluidAudio collapses two or more
/// acoustically close enrolled speakers into one cluster, cluster-centroid
/// matching abstains because the centroid sits between the canonicals. This
/// type re-examines the same cluster at the segment level — each segment
/// votes for its top canonical match, and if multiple canonicals each win
/// a substantial chunk of the votes, we split the cluster.
///
/// Why this works without re-introducing the old "anchored clustering"
/// poisoning vector: voting is per-segment, segments don't move between
/// clusters as a result of voting, and recalculateEmbedding still has its
/// identity-space invariant from The output is just a
/// finer-grained labeling of what the cluster already contains.
struct SubClusterSplitter {

    struct Config {
        /// Per-segment cosine sim threshold to be considered a "vote" for a
        /// canonical. Same as `SpeakerMatcher.Config.acceptThreshold` so cluster
        /// and per-segment paths agree on what "confident" means.
        var perSegmentAcceptThreshold: Float
        /// Per-segment top-1 minus top-2 margin required to commit the vote.
        var perSegmentMarginThreshold: Float
        /// A sub-group with fewer segments than this is demoted into the
        /// "unassigned" pile (and ultimately into the cluster's speaker_N).
        /// Avoids spawning sub-clusters from 1-2 noisy votes.
        var minSegmentsPerSubGroup: Int
        /// If a single canonical captures at least this fraction of the
        /// cluster's segments AND no other canonical reaches the
        /// significant-group threshold, we label the whole cluster — including
        /// the unassigned tail — with that canonical. Saves user from a
        /// "speaker_N for 5% of the segments" splinter.
        var dominantFraction: Float
        /// Pool filter: enrolled candidates with fewer DB segments than this
        /// are skipped. Same rationale as `SpeakerMatcher.Config.minSegmentsForCanonical`.
        var minSegmentsForCanonical: Int
        /// After per-segment voting, an UNKNOWN sub-group with at least this
        /// many segments triggers a centroid-match fallback (
        /// follow-up). Below the floor the group's centroid is too noisy to
        /// trust and we leave it as `speaker_N`.
        var minSegmentsForCentroidFallback: Int
        /// Stricter accept threshold for the centroid fallback. Per-segment
        /// matching uses 0.55 because individual sims are noisy; the centroid
        /// of many segments should be cleaner — require > 0.65 here so we
        /// don't pick up averaged noise.
        var fallbackCentroidAcceptThreshold: Float
        /// Margin for the centroid fallback. Same 0.05 as Stage 2 cluster
        /// matcher and per-segment voting.
        var fallbackCentroidMarginThreshold: Float
        /// After a centroid-fallback match, at least this fraction of the
        /// sub-group's segments must have per-seg cosine sim above
        /// `fallbackPurityThreshold` to the matched canonical. Guards against
        /// a 50/50 unknown mix accidentally landing on a third canonical that
        /// happens to sit between them.
        var fallbackPurityFraction: Float
        /// Loose per-segment sim used by the purity check above.
        var fallbackPurityThreshold: Float
        /// Vote with each segment's own vector (segment-own-voice § 4). Off
        /// until the thresholds above are re-swept on the bench: until then
        /// `SpeakerMatcher` feeds the splitter the cluster centroid, exactly
        /// the input it was tuned on. Bench: TEST_RUNNER_VEDIVOX_SPLITTER_OWN_VECTORS=1.
        var useOwnVectors = ProcessInfo.processInfo.environment["VEDIVOX_SPLITTER_OWN_VECTORS"] == "1"

        static let `default` = Config(
            perSegmentAcceptThreshold: 0.55,
            perSegmentMarginThreshold: 0.05,
            minSegmentsPerSubGroup: 5,
            dominantFraction: 0.8,
            minSegmentsForCanonical: 5,
            minSegmentsForCentroidFallback: 5,
            fallbackCentroidAcceptThreshold: 0.65,
            fallbackCentroidMarginThreshold: 0.05,
            fallbackPurityFraction: 0.7,
            fallbackPurityThreshold: 0.5
        )
    }

    /// Stable identifier for a `DiarizationService.DiarizationSegment` —
    /// (start, end) is unique within a meeting and survives any reordering.
    struct SegmentKey: Hashable, Equatable {
        let start: Double
        let end: Double
    }

    /// One sub-group in a split cluster. `speakerId == nil` means "unknown
    /// sub-cluster" — the caller will assign a fresh `speaker_N` label.
    struct SubGroup: Equatable {
        let speakerId: String?
        let displayName: String?
        let segmentKeys: [SegmentKey]
        let avgConfidence: Float?
    }

    enum Decision: Equatable {
        /// Cluster is one speaker — label whole cluster with this canonical.
        case singleMatch(speakerId: String, displayName: String, confidence: Float)
        /// Cluster contains multiple distinct speakers (or a mix of one
        /// canonical + an unknown tail) — relabel per-segment.
        case splitMatches([SubGroup])
        /// No clear pattern (all unassigned, or empty pool, or too sparse).
        /// Caller falls back to cluster-centroid matching.
        case fallBack
    }

    let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    func resolve(
        clusterSegments: [DiarizationService.DiarizationSegment],
        pool: [SpeakerMatcher.Candidate]
    ) -> Decision {
        let candidates = pool.filter { $0.segmentCount >= config.minSegmentsForCanonical }
        guard !candidates.isEmpty else { return .fallBack }
        guard !clusterSegments.isEmpty else { return .fallBack }

        // Per-segment best-canonical voting.
        var perCanonKeys: [String: [SegmentKey]] = [:]
        var perCanonSimSum: [String: Float] = [:]
        var unassignedKeys: [SegmentKey] = []
        var totalEligible = 0

        for seg in clusterSegments {
            let key = SegmentKey(start: seg.start, end: seg.end)
            let emb = seg.embedding
            guard emb.count == 256 else {
                unassignedKeys.append(key)
                continue
            }
            totalEligible += 1

            let scored = candidates
                .map { (id: $0.speakerId, name: $0.displayName, sim: cosineSimilarity(emb, $0.canonical)) }
                .sorted { $0.sim > $1.sim }

            guard let top = scored.first else {
                unassignedKeys.append(key)
                continue
            }
            let secondSim: Float = scored.count >= 2 ? scored[1].sim : 0

            if top.sim >= config.perSegmentAcceptThreshold,
               (top.sim - secondSim) >= config.perSegmentMarginThreshold {
                perCanonKeys[top.id, default: []].append(key)
                perCanonSimSum[top.id, default: 0] += top.sim
            } else {
                unassignedKeys.append(key)
            }
        }

        // No segment voted confidently — let cluster-centroid path handle it.
        if perCanonKeys.isEmpty {
            return .fallBack
        }

        let displayNameById = Dictionary(uniqueKeysWithValues: candidates.map { ($0.speakerId, $0.displayName) })

        // Significant groups: ≥ minSegmentsPerSubGroup voters.
        var significant: [(canonId: String, name: String, keys: [SegmentKey], avgConf: Float)] = []
        var demoted: [SegmentKey] = unassignedKeys

        for (canonId, keys) in perCanonKeys {
            if keys.count >= config.minSegmentsPerSubGroup {
                let avg = perCanonSimSum[canonId, default: 0] / Float(keys.count)
                significant.append((
                    canonId: canonId,
                    name: displayNameById[canonId] ?? "?",
                    keys: keys,
                    avgConf: avg
                ))
            } else {
                // Too few — fold these segments into the unassigned pile.
                demoted.append(contentsOf: keys)
            }
        }

        if significant.isEmpty { return .fallBack }

        let totalSegs = clusterSegments.count

        // Single-dominant fast path: one significant canonical owns at least
        // `dominantFraction` of the cluster — label the whole thing as it.
        if significant.count == 1 {
            let only = significant[0]
            let fraction = Float(only.keys.count) / Float(totalSegs)
            if fraction >= config.dominantFraction {
                return .singleMatch(
                    speakerId: only.canonId,
                    displayName: only.name,
                    confidence: only.avgConf
                )
            }
        }

        // Split path — emit one SubGroup per significant canonical, plus the
        // unassigned tail (if non-empty) as a single unknown sub-group.
        var groups: [SubGroup] = significant.map { sig in
            SubGroup(
                speakerId: sig.canonId,
                displayName: sig.name,
                segmentKeys: sig.keys,
                avgConfidence: sig.avgConf
            )
        }
        if !demoted.isEmpty {
            // Centroid-fallback rescue: when individual votes
            // were too noisy to commit but the unassigned tail's centroid is
            // clearly one canonical, recover it instead of leaking to speaker_N.
            // M7 evidence: cluster 4's unassigned tail had per-segment sims
            // ~0.5 (just below 0.55 threshold) to one speaker's canonical, but its
            // centroid sim was 0.889 — clear single voice that the strict
            // per-seg path missed.
            if let recovered = centroidFallback(
                keys: demoted,
                clusterSegments: clusterSegments,
                pool: candidates
            ) {
                groups.append(SubGroup(
                    speakerId: recovered.canonId,
                    displayName: recovered.name,
                    segmentKeys: demoted,
                    avgConfidence: recovered.confidence
                ))
            } else {
                groups.append(SubGroup(
                    speakerId: nil,
                    displayName: nil,
                    segmentKeys: demoted,
                    avgConfidence: nil
                ))
            }
        }
        return .splitMatches(groups)
    }

    /// Centroid-match rescue for an UNKNOWN sub-group. Uses
    /// `SpeakerRepository.purifiedCentroid` so the centroid drops the
    /// bottom half of segments by similarity to the rough mean — same
    /// algorithm `recalculateEmbedding` uses, which is what produces the
    /// 0.889/0.851-style high-confidence signals the live REJECTED warnings
    /// hint at on M7. Caller logs the outcome so we can tune thresholds
    /// from real data.
    ///
    /// Returns nil if the sub-group is too small, the centroid match doesn't
    /// clear `fallbackCentroidAcceptThreshold` + margin, or the per-segment
    /// purity check finds the centroid was an averaging artefact of a mixed
    /// sub-group (e.g. 50/50 of two unknowns whose mean happens to land near
    /// a third canonical).
    private func centroidFallback(
        keys: [SegmentKey],
        clusterSegments: [DiarizationService.DiarizationSegment],
        pool: [SpeakerMatcher.Candidate]
    ) -> (canonId: String, name: String, confidence: Float)? {
        guard keys.count >= config.minSegmentsForCentroidFallback else { return nil }

        let keySet = Set(keys)
        let subSegments = clusterSegments.filter {
            keySet.contains(SegmentKey(start: $0.start, end: $0.end))
        }
        let embeddings = subSegments.map(\.embedding).filter { $0.count == 256 }
        guard embeddings.count >= config.minSegmentsForCentroidFallback else { return nil }

        // Use the same purified-centroid algorithm as `recalculateEmbedding`
        // so this fallback sees the same high-SNR signal the post-hoc
        // identity-invariant warnings already surface (e.g. sim 0.889 to
        // a known speaker on M7's UNKNOWN tail).
        let recalcConfig = SpeakerRepository.RecalcConfig(
            keepFraction: 0.5,
            minSegmentsAfterFilter: config.minSegmentsForCentroidFallback,
            identityInvariantThresholds: SpeakerRepository.RecalcConfig.default.identityInvariantThresholds
        )
        guard let centroid = SpeakerRepository.purifiedCentroid(
            embeddings: embeddings,
            config: recalcConfig
        ) else { return nil }

        let scored = pool
            .map { (id: $0.speakerId, name: $0.displayName, sim: cosineSimilarity(centroid, $0.canonical)) }
            .sorted { $0.sim > $1.sim }
        guard let top = scored.first, scored.count >= 2 else { return nil }
        let secondSim = scored[1].sim
        let margin = top.sim - secondSim

        Log.info(String(
            format: "Centroid fallback: %d segs → top=%@ sim=%.3f, runner-up=%@ sim=%.3f, margin=%.3f",
            embeddings.count, top.name, top.sim,
            scored[1].name, secondSim, margin
        ))

        guard top.sim >= config.fallbackCentroidAcceptThreshold,
              margin >= config.fallbackCentroidMarginThreshold
        else {
            Log.info("Centroid fallback: skipped (sim < \(config.fallbackCentroidAcceptThreshold) or margin < \(config.fallbackCentroidMarginThreshold))")
            return nil
        }

        // Purity verification — drops the rescue if the centroid hit was an
        // averaging artefact of a mixed sub-group whose mean happens to sit
        // near a third canonical. We compare each segment to the matched
        // canonical, not the centroid, so the check is independent of the
        // averaging step.
        let topCanonical = pool.first { $0.speakerId == top.id }!.canonical
        let purityCount = embeddings.filter {
            cosineSimilarity($0, topCanonical) >= config.fallbackPurityThreshold
        }.count
        let purity = Float(purityCount) / Float(embeddings.count)

        guard purity >= config.fallbackPurityFraction else {
            Log.info(String(
                format: "Centroid fallback: purity=%.2f < %.2f, skipping rescue (likely mixed sub-group)",
                purity, config.fallbackPurityFraction
            ))
            return nil
        }

        Log.info(String(
            format: "Centroid fallback: rescued sub-group → %@ (sim %.3f, purity %.2f)",
            top.name, top.sim, purity
        ))
        return (canonId: top.id, name: top.name, confidence: top.sim)
    }
}
