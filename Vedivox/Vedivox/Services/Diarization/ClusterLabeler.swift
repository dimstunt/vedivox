import Foundation

/// Translates FluidAudio's anonymous within-meeting cluster ids ("1", "2", ...)
/// to display-friendly labels using two-stage matcher decisions. Extracted from
/// `TranscriptionPipeline.applyMatcherResults` so the persona policy
/// below is unit-testable without a database.
///
/// Three resolution shapes are handled:
/// - `matched` — whole cluster gets one enrolled speaker's `displayName`.
/// - `splitMatches` — cluster is over-merged; per-segment
///   relabel maps each segment to its winning canonical (or to a fresh
///   `speaker_N` for the unknown sub-group).
/// - `unmatched` — fresh `speaker_N`, but only past the mass gate (below).
///
/// Persona mass gate: the offline diarizer over-clusters 1:1 calls
/// into micro-clusters of 1–23s (echo, noise, ASR fringe), and minting a
/// `speaker_N` persona for each pollutes the speakers table — every phantom
/// becomes a matching magnet for future meetings. A cluster the enrolled pool
/// rejected (low-sim/ambiguous) whose speech mass is below
/// `max(minNewSpeakerMassSeconds, minNewSpeakerMassFraction × track mass)`
/// therefore never mints a persona: it is folded into the acoustically
/// nearest resolved cluster of the same track (centroid sim ≥
/// `mergeSimilarityThreshold`) or demoted to UNKNOWN, which
/// `createSpeakersFromDiarization` never persists. Empty-pool abstains bypass
/// the gate — there speaker_N labels are the entire output.
struct ClusterLabeler {

    struct Config {
        /// Absolute floor: minimum total speech (seconds) an unmatched cluster
        /// or unknown sub-group needs to mint a new `speaker_N` persona.
        var minNewSpeakerMassSeconds: Double
        /// Relative floor: fraction of the track's total speech mass. The
        /// effective floor is `max(seconds, fraction × trackMass)`, so a 40-min
        /// 1:1 demotes its 1–23s junk (2.5% ≈ 27–38s) while a short dense
        /// group call keeps its quiet-but-real speakers (bench M5: 8 speakers
        /// in 405s — a hard 30s floor cost +6.9s DER there).
        var minNewSpeakerMassFraction: Double
        /// A below-floor cluster whose centroid scores at least this against
        /// a resolved cluster's centroid is folded into that cluster instead
        /// of UNKNOWN. Within one track both centroids live in the same
        /// embedder space; 0.70 sits well above the 0.40–0.49 junk band from
        /// the audit.
        var mergeSimilarityThreshold: Float
        /// When false, unmatched clusters never mint `speaker_N` regardless of
        /// mass — they fold or demote to UNKNOWN. Production leaves it on for
        /// both tracks: other voices on the mic get a row so «participant» can
        /// show them at once (foreign-voices-on-mic), and the foreign-voice
        /// policy hides their lines; those rows never enter the matching pool.
        var mintNewSpeakers: Bool = true
        /// A cluster the pool rejected but which sounds like a cluster of this
        /// track already matched to someone is that person, not a new voice:
        /// the diarizer split one voice in two, and only one half resembled
        /// the canonical. Same meeting, same track — the centroids share the
        /// conditions the canonical lacks. Different named people of one
        /// meeting and track reach 0.80 in 0.3% of pairs (2026-11-23).
        var continuitySimilarity: Float = 0.80
        /// …and only when that person leads every other matched one by this.
        var continuityMargin: Float = 0.10

        static let `default` = Config(
            minNewSpeakerMassSeconds: 10,
            minNewSpeakerMassFraction: 0.025,
            mergeSimilarityThreshold: 0.70
        )

        /// Bench sweep knobs: VEDIVOX_MIN_CLUSTER_MASS (seconds),
        /// VEDIVOX_MIN_CLUSTER_MASS_FRAC (0..1 of track speech),
        /// VEDIVOX_MICROCLUSTER_MERGE_SIM (0..1 cosine sim).
        static func fromEnvironment() -> Config {
            let env = ProcessInfo.processInfo.environment
            var config = Config.default
            if let raw = env["VEDIVOX_MIN_CLUSTER_MASS"], let v = Double(raw) {
                config.minNewSpeakerMassSeconds = v
            }
            if let raw = env["VEDIVOX_MIN_CLUSTER_MASS_FRAC"], let v = Double(raw) {
                config.minNewSpeakerMassFraction = v
            }
            if let raw = env["VEDIVOX_MICROCLUSTER_MERGE_SIM"], let v = Float(raw) {
                config.mergeSimilarityThreshold = v
            }
            return config
        }
    }

    struct Output {
        let segments: [DiarizationService.DiarizationSegment]
        /// Every enrolled-speaker label encountered, so downstream code can
        /// link segments without re-querying.
        let labelToDbId: [String: String]
    }

    let config: Config

    init(config: Config = .fromEnvironment()) {
        self.config = config
    }

    /// `reservedLabels`: labels already used elsewhere in this meeting (the
    /// other track) — minting continues after their highest `speaker_N` so a
    /// label never names two different voices within one meeting
    /// (speaker-row-per-mint).
    /// `boundLabels`: labels already bound to records in this meeting — an
    /// enrolled match reuses its record's label there, and a different record
    /// with the same name gets a distinct one (stage2-out-of-pool).
    func apply(
        _ segments: [DiarizationService.DiarizationSegment],
        speakerEmbeddings: [String: [Float]],
        matchResults: [String: SpeakerMatcher.Resolution],
        reservedLabels: Set<String> = [],
        boundLabels: [String: String] = [:]
    ) -> Output {
        var idToDisplayName: [String: String] = [:] // cluster_id → label (matched / unmatched whole-cluster)
        var perSegmentLabel: [SubClusterSplitter.SegmentKey: String] = [:] // (start, end) → label (split case)
        // One label, one record: keyed by display name, two records called the
        // same (two confirmed `speaker_1`) collapsed into one speakerId.
        var book = SpeakerLabelBook(bindings: boundLabels, reserved: reservedLabels)

        // Total speech seconds per stage-1 cluster — input to the mass gate.
        var clusterMass: [String: Double] = [:]
        for seg in segments {
            clusterMass[seg.speaker, default: 0] += max(0, seg.end - seg.start)
        }
        let trackMass = clusterMass.values.reduce(0, +)
        let massFloor = max(
            config.minNewSpeakerMassSeconds,
            config.minNewSpeakerMassFraction * trackMass
        )

        // First pass — confident whole-cluster matches and split decisions.
        // Splits are still logged at the cluster level so the audit trail is
        // legible: one log line per cluster, with per-sub-group breakdown.
        for clusterId in matchResults.keys.sorted() {
            switch matchResults[clusterId]! {
            case .matched(let speakerId, let displayName, let confidence):
                let label = book.label(for: displayName, speakerId: speakerId)
                idToDisplayName[clusterId] = label
                Log.info("Two-stage: cluster \(clusterId) → \(label) (sim=\(String(format: "%.3f", confidence)))")

            case .splitMatches(let groups):
                // Per-segment relabel. Enrolled sub-groups carry a real label;
                // the unknown sub-group is resolved in the second pass (needs
                // stable speaker_N numbering / mass gate).
                var summary: [String] = []
                for group in groups {
                    if let speakerId = group.speakerId, let displayName = group.displayName {
                        let label = book.label(for: displayName, speakerId: speakerId)
                        for key in group.segmentKeys {
                            perSegmentLabel[key] = label
                        }
                        let conf = group.avgConfidence.map { String(format: "%.3f", $0) } ?? "?"
                        summary.append("\(label): \(group.segmentKeys.count) (avg sim \(conf))")
                    }
                }
                if let unknownGroup = groups.first(where: { $0.speakerId == nil }) {
                    summary.append("UNKNOWN: \(unknownGroup.segmentKeys.count)")
                }
                Log.info("Two-stage: cluster \(clusterId) SPLIT — \(summary.joined(separator: ", "))")

            case .unmatched:
                continue // handled in second pass
            }
        }

        // Second pass — unmatched clusters and unknown sub-groups become
        // `speaker_N` identities when they clear the mass gate. Number after
        // the highest speaker_* already taken — by an enrolled label like
        // "speaker_3" (whole cluster or split sub-group) or by the meeting's
        // other track (reservedLabels).
        var nextNew = book.highestAutoNumber()

        // 2a. Unmatched clusters with enough mass mint a fresh persona.
        // Below-floor ones are deferred so they can fold into labels minted here.
        //
        // The gate only fires when a pool existed and rejected the cluster
        // (lowSimilarity / ambiguousMargin): that's the phantom signature —
        // junk the enrolled speakers already disowned. With an empty pool
        // (unenrolled import, stage-1 bench) speaker_N labels are the entire
        // output and demoting them would erase real speakers.
        var microClusters: [String] = []
        let matchedClusters = idToDisplayName // first pass: enrolled matches only
        for clusterId in speakerEmbeddings.keys.sorted() {
            guard case .unmatched(let reason) = matchResults[clusterId] else { continue }
            let mass = clusterMass[clusterId] ?? 0
            if config.mintNewSpeakers, reason == .emptyPool || mass >= massFloor {
                if let (label, sim) = sameVoice(as: clusterId, among: matchedClusters, speakerEmbeddings: speakerEmbeddings) {
                    idToDisplayName[clusterId] = label
                    Log.info("Two-stage: cluster \(clusterId) → \(label) (mass \(String(format: "%.1f", mass))s, same voice as its matched cluster here, centroid sim \(String(format: "%.3f", sim)); \(describe(reason)))")
                    continue
                }
                nextNew += 1
                let label = "speaker_\(nextNew)"
                idToDisplayName[clusterId] = label
                Log.info("Two-stage: cluster \(clusterId) → \(label) (mass \(String(format: "%.1f", mass))s, \(describe(reason)))")
            } else {
                microClusters.append(clusterId)
            }
        }

        // 2b. Unknown sub-groups of split clusters — same mass gate, applied
        // per-segment because the rest of the cluster keeps its enrolled labels.
        for clusterId in matchResults.keys.sorted() {
            guard case .splitMatches(let groups) = matchResults[clusterId],
                  let unknownGroup = groups.first(where: { $0.speakerId == nil })
            else { continue }
            let mass = unknownGroup.segmentKeys.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            if config.mintNewSpeakers, mass >= massFloor {
                nextNew += 1
                let label = "speaker_\(nextNew)"
                for key in unknownGroup.segmentKeys {
                    perSegmentLabel[key] = label
                }
                Log.info("Two-stage: cluster \(clusterId) UNKNOWN sub-group → \(label) (\(unknownGroup.segmentKeys.count) segs, mass \(String(format: "%.1f", mass))s)")
            } else {
                for key in unknownGroup.segmentKeys {
                    perSegmentLabel[key] = "UNKNOWN"
                }
                Log.info("Two-stage: cluster \(clusterId) UNKNOWN sub-group → UNKNOWN (mass \(String(format: "%.1f", mass))s < \(String(format: "%.1f", massFloor))s floor, no persona)")
            }
        }

        // 2c. Micro-clusters: fold into the nearest resolved cluster of this
        // track, else UNKNOWN. Targets are snapshotted before any micro-cluster
        // is labeled so junk can't chain onto other junk's UNKNOWN label.
        let foldTargets = idToDisplayName
        for clusterId in microClusters {
            let mass = clusterMass[clusterId] ?? 0
            // Best pool candidate, so a lost micro-cluster's near miss is visible in the log.
            var pool = ""
            if case .unmatched(let reason) = matchResults[clusterId] { pool = "; \(describe(reason))" }
            if let (label, sim) = nearestResolvedCluster(
                to: clusterId,
                targets: foldTargets,
                speakerEmbeddings: speakerEmbeddings
            ) {
                idToDisplayName[clusterId] = label
                Log.info("Two-stage: cluster \(clusterId) micro (mass \(String(format: "%.1f", mass))s) folded into \(label) (centroid sim \(String(format: "%.3f", sim))\(pool))")
            } else {
                idToDisplayName[clusterId] = "UNKNOWN"
                let why = config.mintNewSpeakers
                    ? "mass \(String(format: "%.1f", mass))s < \(String(format: "%.1f", massFloor))s floor"
                    : "mass \(String(format: "%.1f", mass))s, minting disabled on this track"
                Log.info("Two-stage: cluster \(clusterId) micro (\(why)\(pool)) → UNKNOWN, no persona")
            }
        }

        // Every cluster with a centroid gets resolved above. One without a
        // centroid (the diarizer built speakerEmbeddings from a different
        // segment set than it returned) has no resolution at all, and its raw
        // id must not leak out — the pipeline would mint a persona named "1"
        // from it. Demote to UNKNOWN and say so.
        var unresolved: Set<String> = []
        let remapped = segments.map { seg -> DiarizationService.DiarizationSegment in
            let key = SubClusterSplitter.SegmentKey(start: seg.start, end: seg.end)
            var label = perSegmentLabel[key] ?? idToDisplayName[seg.speaker]
            if label == nil {
                if unresolved.insert(seg.speaker).inserted {
                    Log.warning("Two-stage: cluster \(seg.speaker) has segments but no centroid/match result — demoting to UNKNOWN")
                }
                label = "UNKNOWN"
            }
            return DiarizationService.DiarizationSegment(
                start: seg.start,
                end: seg.end,
                speaker: label ?? "UNKNOWN",
                embedding: seg.embedding
            )
        }
        return Output(segments: remapped, labelToDbId: book.bindings)
    }

    /// Best fold target for a micro-cluster: highest centroid similarity among
    /// already-resolved whole clusters, if it clears `mergeSimilarityThreshold`.
    private func nearestResolvedCluster(
        to clusterId: String,
        targets: [String: String],
        speakerEmbeddings: [String: [Float]]
    ) -> (label: String, sim: Float)? {
        guard let centroid = speakerEmbeddings[clusterId], !centroid.isEmpty else { return nil }
        var best: (label: String, sim: Float)?
        for (otherId, label) in targets where otherId != clusterId {
            guard let other = speakerEmbeddings[otherId], other.count == centroid.count else { continue }
            let sim = cosineSimilarity(centroid, other)
            if best == nil || sim > best!.sim {
                best = (label, sim)
            }
        }
        guard let best, best.sim >= config.mergeSimilarityThreshold else { return nil }
        return best
    }

    /// The matched person of this track the cluster sounds like, when it
    /// reaches `continuitySimilarity` and leads every other matched person by
    /// `continuityMargin` (best centroid per person).
    private func sameVoice(
        as clusterId: String, among matched: [String: String], speakerEmbeddings: [String: [Float]]
    ) -> (label: String, sim: Float)? {
        guard let centroid = speakerEmbeddings[clusterId], !centroid.isEmpty else { return nil }
        var bestPerLabel: [String: Float] = [:]
        for (otherId, label) in matched {
            guard let other = speakerEmbeddings[otherId], other.count == centroid.count else { continue }
            bestPerLabel[label] = max(bestPerLabel[label] ?? -1, cosineSimilarity(centroid, other))
        }
        let ranked = bestPerLabel.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard let best = ranked.first, best.value >= config.continuitySimilarity else { return nil }
        if ranked.count > 1, best.value - ranked[1].value < config.continuityMargin { return nil }
        return (best.key, best.value)
    }

    private func describe(_ reason: SpeakerMatcher.AbstainReason) -> String {
        switch reason {
        case .lowSimilarity(let topSim, let topName):
            return "low sim — best=\(topName ?? "?") \(String(format: "%.3f", topSim))" + nearMiss(topSim, topName)
        case .ambiguousMargin(let topSim, let margin, let topName, let runnerUpName):
            return "ambiguous — \(topName) \(String(format: "%.3f", topSim)) vs \(runnerUpName) (margin \(String(format: "%.3f", margin)))"
        case .emptyPool:
            return "empty pool"
        case .tooShort(let mass, let topSim, let topName):
            return "too short to decide (\(String(format: "%.1f", mass))s) — best=\(topName ?? "?") \(String(format: "%.3f", topSim))"
        }
    }

    /// Quiet "looks like X" hint for the dead zone below the accept threshold
    /// (stage2-dead-zone): log only, no state, nothing for the user to confirm.
    private func nearMiss(_ topSim: Float, _ topName: String?) -> String {
        guard let topName, topSim >= 0.50 else { return "" }
        return "; near-miss: looks like \(topName) (dead zone)"
    }
}
