import Foundation

/// Periodic safety net that checks for canonical-embedding collisions across the
/// confirmed enrollment pool.
///
/// Even with `recalculateEmbedding`'s identity invariant blocking
/// new collisions on save, an unrelated path could still introduce one — manual
/// `mergeSpeakers`, future code that bypasses the invariant, a botched migration,
/// or pre-existing collisions in older DBs. This monitor catches them by running
/// the same offline check that `scripts/speaker_similarity.py` performs, but
/// inside the app, on a schedule.
///
/// Behaviour:
/// - On `runCheck()`, computes pairwise cosine similarity for every pair of
///   confirmed enrolled speakers with embeddings.
/// - Returns the list of pairs whose sim exceeds `driftThreshold` (by default the
///   identity-invariant threshold of the active embedding space).
/// - Throttled: subsequent calls within `minIntervalSeconds` return the last
///   result without recomputing — prevents app-launch storms from re-querying
///   the DB constantly.
///
/// Wiring is intentionally minimal in this commit — the actor is callable from
/// any async context. Surfacing alerts in the UI (badge in Speakers tab, etc.)
/// is a follow-up; for now alerts just hit the log.
actor SpeakerDriftMonitor {

    struct Config {
        /// Pair sim above this triggers an alert. Audit baseline: pairs > 0.6 are
        /// almost always merged identities; clean speakers cap around 0.5.
        var driftThreshold: Float
        /// Don't recompute more often than this (in seconds). Returns cached result.
        var minIntervalSeconds: TimeInterval
        /// Canonical space to check — the one matching runs in.
        var space: EmbeddingSpace = .v1

        /// The space of the active diarizer.
        static var `default`: Config {
            forSpace(DiarizationService.useOfflineDiarizer ? .v2 : .v1)
        }

        /// Threshold: the hard cap of the separability invariant where it
        /// applies (v2 — honest lookalikes legitimately sit at 0.75–0.80 and
        /// must not alarm every hour), else the identity threshold (v1).
        static func forSpace(_ space: EmbeddingSpace) -> Config {
            let recalc = SpeakerRepository.RecalcConfig.default
            return Config(
                driftThreshold: recalc.separability.hardCap[space] ?? recalc.identityInvariantThreshold(for: space),
                minIntervalSeconds: 3600,
                space: space
            )
        }
    }

    /// One pair of speakers that look acoustically too close.
    struct DriftAlert: Equatable, Sendable {
        let speakerAId: String
        let speakerAName: String
        let speakerBId: String
        let speakerBName: String
        let similarity: Float
    }

    private let repo: SpeakerRepository
    private let config: Config
    private var lastCheckAt: Date?
    private var lastResult: [DriftAlert] = []

    init(repo: SpeakerRepository = SpeakerRepository(), config: Config = .default) {
        self.repo = repo
        self.config = config
    }

    /// Number of pairs above threshold from the most recent run, or nil if not yet run.
    var lastAlertCount: Int? {
        lastCheckAt == nil ? nil : lastResult.count
    }

    /// Run the pairwise check. If the previous run was within
    /// `minIntervalSeconds` and `force` is false, returns the cached result
    /// without touching the DB.
    @discardableResult
    func runCheck(force: Bool = false) async throws -> [DriftAlert] {
        if !force, let last = lastCheckAt,
           Date().timeIntervalSince(last) < config.minIntervalSeconds {
            return lastResult
        }

        let speakers = try await repo.confirmedSpeakersWithEmbeddings(space: config.space)
        let alerts = computeAlerts(from: speakers, threshold: config.driftThreshold)

        lastCheckAt = Date()
        lastResult = alerts

        if alerts.isEmpty {
            Log.info("DriftMonitor: no canonical collisions among \(speakers.count) confirmed enrolled (threshold \(config.driftThreshold))")
        } else {
            Log.warning("DriftMonitor: \(alerts.count) canonical collisions found (threshold \(config.driftThreshold)):")
            for a in alerts {
                Log.warning("  sim=\(String(format: "%.3f", a.similarity))  \(a.speakerAName) ↔ \(a.speakerBName)")
            }
        }
        return alerts
    }

    /// Pure helper — exposed for unit tests.
    static func computeAlerts(
        from speakers: [(id: String, name: String, canonical: [Float])],
        threshold: Float
    ) -> [DriftAlert] {
        var out: [DriftAlert] = []
        for i in 0 ..< speakers.count {
            for j in (i + 1) ..< speakers.count {
                let a = speakers[i], b = speakers[j]
                let sim = cosineSimilarity(a.canonical, b.canonical)
                if sim > threshold {
                    out.append(DriftAlert(
                        speakerAId: a.id, speakerAName: a.name,
                        speakerBId: b.id, speakerBName: b.name,
                        similarity: sim
                    ))
                }
            }
        }
        // Worst pair first — most-suspicious shows up at the top of the log.
        out.sort { $0.similarity > $1.similarity }
        return out
    }

    private func computeAlerts(
        from speakers: [(id: String, name: String, canonical: [Float])],
        threshold: Float
    ) -> [DriftAlert] {
        Self.computeAlerts(from: speakers, threshold: threshold)
    }
}
