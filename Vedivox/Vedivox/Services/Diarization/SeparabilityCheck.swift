import Foundation

/// Identity invariant by separability (separability-invariant, design § 1).
///
/// A cosine threshold between two canonicals measures how alike two voices
/// sound, not whether the people can be told apart: honest lookalikes sit at
/// 0.76–0.79 in v2, poisoned pairs start at 0.82. This check asks the second
/// question per meeting voice: is the voice closer to its own speaker's
/// canonical built WITHOUT it than to the nearest other confirmed speaker?
/// Pure — no database; the repository supplies the neighbours' live canonicals.
enum SeparabilityCheck {

    struct Config: Equatable {
        /// Reject when more than this fraction of voices has a negative gap.
        var maxNegativeShare: Float = 0.20
        /// Reject when those voices carry more than this fraction of the speech.
        var maxNegativeMass: Float = 0.10
        /// Reject when the median gap is below this.
        var minMedianGap: Float = 0.05
        /// Canonical-to-canonical ceiling, whatever the gaps say. A space
        /// without an entry does not use this check at all (v1).
        var hardCap: [EmbeddingSpace: Float] = [.v2: 0.90]
        /// Below this many voices leave-one-out is meaningless: the plain
        /// identity threshold applies instead.
        var minVoices = 3
        /// Shortlist (design § 2): a neighbour is checked when its stored
        /// canonical is within this margin of a voice's own similarity…
        var neighborMargin: Float = 0.10
        /// …or at least this close to the new canonical.
        var neighborCanonicalSim: Float = 0.60
        var maxNeighbors = 5
    }

    struct Neighbor: Equatable, Sendable {
        let id: String
        let name: String
        let canonical: [Float]
    }

    /// One meeting voice against its own speaker and the nearest neighbour.
    struct VoiceGap: Equatable {
        let meetingId: String
        let seconds: Double
        /// Similarity to the own canonical built without this voice (a voice
        /// the outlier filter dropped is not in it to begin with).
        let own: Float
        /// Similarity to the nearest neighbour's canonical.
        let other: Float
        /// Index of that neighbour in the evaluated list.
        let neighbor: Int
        var gap: Float { own - other }
    }

    enum Verdict: Equatable {
        case separable
        /// Canonicals nearly coincide (hard cap), or too few voices and the
        /// plain threshold is exceeded.
        case tooSimilar(id: String, name: String, sim: Float)
        /// Voices cannot be told apart from `name`. `share` is the speech
        /// fraction of the voices closer to a neighbour, `meetings` their ids
        /// by descending speech; `sim` is canonical to canonical.
        case inseparable(id: String, name: String, sim: Float, share: Float, meetings: [String])
    }

    struct Result: Equatable {
        let verdict: Verdict
        let gaps: [VoiceGap]
        let neighbors: [Neighbor]
        let negativeShare: Float
        let negativeMass: Float
        /// nil when the gaps were not evaluated (too few voices, no neighbours).
        let medianGap: Float?

        /// Every number behind the verdict, for the log.
        var logDescription: String {
            let negatives = gaps.filter { $0.gap < 0 }
            let head = "\(gaps.count) voice(s), \(negatives.count) closer to a neighbour "
                + "(\(Self.percent(negativeShare)) of voices, \(Self.percent(negativeMass)) of speech), "
                + "median gap \(medianGap.map { String(format: "%.3f", $0) } ?? "n/a")"
            let lines = negatives.map { gap in
                "meeting \(gap.meetingId) (\(Int(gap.seconds))s): own "
                    + String(format: "%.3f", gap.own) + ", other " + String(format: "%.3f", gap.other)
                    + " to '\(neighbors[gap.neighbor].name)'"
            }
            return ([head] + lines).joined(separator: "; ")
        }

        private static func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }
    }

    /// Every judged voice with its similarity to the own canonical: voices in
    /// the canonical leave-one-out, dropped ones against the canonical as is.
    static func judgedVoices(
        _ selection: SpeakerRepository.CanonicalSelection
    ) -> [(voice: SpeakerRepository.MeetingVoice, own: Float)] {
        let own = ownSimilarities(selection.voices)
        return zip(selection.voices, own).map { ($0.voice, $1) }
            + selection.dropped
            .filter { $0.embedding.count == selection.canonical.count }
            .map { ($0, cosineSimilarity($0.embedding, selection.canonical)) }
    }

    /// Similarity of each voice to the weighted canonical without that voice:
    /// `Σ wᵢvᵢ − w·v`. The meeting selection is not rerun.
    static func ownSimilarities(_ voices: [SpeakerRepository.WeightedVoice]) -> [Float] {
        guard let dim = voices.first?.voice.embedding.count else { return [] }
        var sum = [Float](repeating: 0, count: dim)
        for item in voices {
            for i in 0 ..< dim { sum[i] += item.weight * item.voice.embedding[i] }
        }
        return voices.map { item in
            var rest = sum
            for i in 0 ..< dim { rest[i] -= item.weight * item.voice.embedding[i] }
            return cosineSimilarity(item.voice.embedding, rest)
        }
    }

    /// Which neighbours are worth a live canonical (design § 2). `columns` are
    /// STORED canonicals: they pick who gets checked and never reject anyone.
    static func shortlist(
        _ selection: SpeakerRepository.CanonicalSelection,
        columns: [Neighbor],
        config: Config
    ) -> [Neighbor] {
        // A single voice has no leave-one-out; the canonical rule covers it.
        let judged = selection.voices.count > 1 ? judgedVoices(selection) : []
        let scored: [(neighbor: Neighbor, sim: Float)] = columns.compactMap { neighbor in
            guard neighbor.canonical.count == selection.canonical.count else { return nil }
            let canonicalSim = cosineSimilarity(selection.canonical, neighbor.canonical)
            var best = canonicalSim
            var picked = canonicalSim >= config.neighborCanonicalSim
            for item in judged {
                let sim = cosineSimilarity(item.voice.embedding, neighbor.canonical)
                if sim >= item.own - config.neighborMargin { picked = true }
                best = max(best, sim)
            }
            return picked ? (neighbor, best) : nil
        }
        return scored.sorted { $0.sim > $1.sim }.prefix(config.maxNeighbors).map(\.neighbor)
    }

    /// `neighbors` carry LIVE canonicals. A rejection by the gaps wins over
    /// the canonical ceiling: it names the meetings to listen to.
    static func evaluate(
        _ selection: SpeakerRepository.CanonicalSelection,
        neighbors: [Neighbor],
        config: SpeakerRepository.RecalcConfig,
        space: EmbeddingSpace
    ) -> Result {
        let knobs = config.separability
        let neighbors = neighbors.filter { $0.canonical.count == selection.canonical.count }
        let enough = selection.voices.count >= knobs.minVoices
        let plain = config.identityInvariantThreshold(for: space)
        let ceiling = enough ? knobs.hardCap[space] ?? plain : plain

        let canonicalSims = neighbors.map { cosineSimilarity(selection.canonical, $0.canonical) }
        var verdict = Verdict.separable
        if let worst = canonicalSims.indices.max(by: { canonicalSims[$0] < canonicalSims[$1] }),
           canonicalSims[worst] > ceiling {
            verdict = .tooSimilar(id: neighbors[worst].id, name: neighbors[worst].name, sim: canonicalSims[worst])
        }
        guard enough, !neighbors.isEmpty else {
            return Result(verdict: verdict, gaps: [], neighbors: neighbors,
                          negativeShare: 0, negativeMass: 0, medianGap: nil)
        }

        let gaps: [VoiceGap] = judgedVoices(selection).map { item in
            let sims = neighbors.map { cosineSimilarity(item.voice.embedding, $0.canonical) }
            let nearest = sims.indices.max { sims[$0] < sims[$1] } ?? 0
            return VoiceGap(meetingId: item.voice.meetingId, seconds: item.voice.speechSeconds,
                            own: item.own, other: sims[nearest], neighbor: nearest)
        }
        let negatives = gaps.filter { $0.gap < 0 }.sorted { $0.seconds > $1.seconds }
        let totalSeconds = gaps.reduce(0) { $0 + $1.seconds }
        let share = Float(negatives.count) / Float(gaps.count)
        let mass = totalSeconds > 0 ? Float(negatives.reduce(0) { $0 + $1.seconds } / totalSeconds) : 0
        let sorted = gaps.map(\.gap).sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2

        if share > knobs.maxNegativeShare || mass > knobs.maxNegativeMass || median < knobs.minMedianGap {
            // Named neighbour: the one the offending speech is closest to; with
            // no offending voice (median only), the one nearest to most speech.
            var secondsByNeighbor: [Int: Double] = [:]
            for gap in negatives.isEmpty ? gaps : negatives {
                secondsByNeighbor[gap.neighbor, default: 0] += gap.seconds
            }
            // Ties broken by index so the verdict is deterministic.
            let named = secondsByNeighbor.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? 0
            verdict = .inseparable(
                id: neighbors[named].id, name: neighbors[named].name, sim: canonicalSims[named],
                share: mass, meetings: negatives.map(\.meetingId)
            )
        }
        return Result(verdict: verdict, gaps: gaps, neighbors: neighbors,
                      negativeShare: share, negativeMass: mass, medianGap: median)
    }
}
