import Foundation

/// Overlap-aware DER scorer on a fixed frame grid (md-eval semantics).
///
/// Each frame holds a SET of speakers on both sides, so overlapping segments —
/// legal on the pred side (mic + system tracks merged, multi-speaker-on-one-mic)
/// and in gt.json (same-speaker overlaps) — are scored, not collapsed to an
/// arbitrary last-writer label like the pre-scorer did.
///
/// Per frame, with `nRef = |ref set|`, `nPred = |pred set|` and an injective
/// pred→ref mapping built from the co-occurrence matrix:
///   missed      = max(0, nRef − nPred)
///   false alarm = max(0, nPred − nRef)
///   confusion   = min(nRef, nPred) − |{p ∈ pred : map(p) ∈ ref}|
/// Totals are speaker-seconds (refSpeech = Σ nRef), matching md-eval/pyannote.
struct DERScorer {
    struct Segment {
        let start: Double
        let end: Double
        let key: String
    }

    struct Result {
        let derSeconds: Double
        let missedSeconds: Double
        let falseAlarmSeconds: Double
        let confusionSeconds: Double
        let refSpeechSeconds: Double
        /// Injective greedy mapping, by descending co-occurrence.
        let predToRef: [String: String]
        /// ref speaker → pred key with the most co-occurring speaker-frames
        /// (consumed by the cross-meeting consistency check).
        let realToPred: [String: String]
        /// Boundary localization (Tier-1 brainstorm 2026-06-12): mean distance
        /// from each reference speaker-change point to the nearest predicted
        /// one, capped at 2.0s per change. nil when the reference has no
        /// speaker changes. Tracks the "boundary drifts ~1s" error class that
        /// confusion seconds barely move on.
        let boundaryMAESeconds: Double?
        let refSpeakerChangeCount: Int
        /// Fraction of reference segments shorter than 2.5s whose frames are
        /// majority-covered by a correctly-mapped pred speaker. Tracks the
        /// "short interjection dissolves" error class. nil when the reference
        /// has no short segments.
        let shortUtteranceRecall: Double?
        let shortUtteranceCount: Int
        /// pyannote purity: Σ_pred max_ref |pred∩ref| / Σ_pred |pred| over the
        /// scored frames. Two people in one pred cluster lower it.
        let purity: Double
        /// pyannote coverage: Σ_ref max_pred |pred∩ref| / Σ_ref |ref|. One person
        /// split over several pred clusters lowers it.
        let coverage: Double
    }

    let frameStep: Double

    init(frameStep: Double = 0.01) {
        self.frameStep = frameStep
    }

    func score(
        predicted: [Segment],
        reference: [Segment],
        windowLengthSeconds: Double,
        collarSeconds: Double = 0
    ) -> Result {
        let n = max(0, Int((windowLengthSeconds / frameStep).rounded()))
        var refGrid = [Set<String>](repeating: [], count: n)
        var predGrid = [Set<String>](repeating: [], count: n)

        func fill(_ grid: inout [Set<String>], _ segments: [Segment]) {
            for s in segments {
                let i0 = max(0, Int((s.start / frameStep).rounded()))
                let i1 = min(n, Int((s.end / frameStep).rounded()))
                if i0 < i1 { for i in i0 ..< i1 { grid[i].insert(s.key) } }
            }
        }
        fill(&refGrid, reference)
        fill(&predGrid, predicted)

        // md-eval collar: frames within ±collar of any reference segment
        // boundary are not scored (DER, mapping, purity/coverage).
        var scored = [Bool](repeating: true, count: n)
        if collarSeconds > 0 {
            for s in reference {
                for t in [s.start, s.end] {
                    let i0 = max(0, Int(((t - collarSeconds) / frameStep).rounded()))
                    let i1 = min(n, Int(((t + collarSeconds) / frameStep).rounded()))
                    if i0 < i1 { for i in i0 ..< i1 { scored[i] = false } }
                }
            }
        }

        // Co-occurrence over the full set product per frame.
        var cooc: [String: [String: Int]] = [:]
        var predFrames: [String: Int] = [:], refFrames: [String: Int] = [:]
        for i in 0 ..< n where scored[i] {
            for p in predGrid[i] { predFrames[p, default: 0] += 1 }
            for r in refGrid[i] { refFrames[r, default: 0] += 1 }
            for p in predGrid[i] {
                for r in refGrid[i] {
                    cooc[p, default: [:]][r, default: 0] += 1
                }
            }
        }

        // Greedy injective pred→ref mapping that maximizes frame agreement.
        var pairs: [(pred: String, ref: String, count: Int)] = []
        for (pred, refs) in cooc { for (ref, c) in refs { pairs.append((pred, ref, c)) } }
        pairs.sort { ($0.count, $0.pred) > ($1.count, $1.pred) }
        var predToRef: [String: String] = [:]
        var usedRef = Set<String>()
        for p in pairs where predToRef[p.pred] == nil && !usedRef.contains(p.ref) {
            predToRef[p.pred] = p.ref
            usedRef.insert(p.ref)
        }

        var missed = 0, falseAlarm = 0, confusion = 0, refSpeech = 0
        for i in 0 ..< n where scored[i] {
            let ref = refGrid[i], pred = predGrid[i]
            refSpeech += ref.count
            let correct = pred.count { p in
                if let mapped = predToRef[p] { ref.contains(mapped) } else { false }
            }
            missed += max(0, ref.count - pred.count)
            falseAlarm += max(0, pred.count - ref.count)
            confusion += min(ref.count, pred.count) - correct
        }

        var realToPred: [String: String] = [:]
        var byReal: [String: [String: Int]] = [:]
        for (pred, refs) in cooc { for (ref, c) in refs { byReal[ref, default: [:]][pred, default: 0] += c } }
        for (real, preds) in byReal {
            realToPred[real] = preds.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        }
        let purityHits = cooc.values.reduce(0) { $0 + ($1.values.max() ?? 0) }
        let coverageHits = byReal.values.reduce(0) { $0 + ($1.values.max() ?? 0) }
        let predTotal = predFrames.values.reduce(0, +), refTotal = refFrames.values.reduce(0, +)

        // Boundary MAE: speaker-change points are frames where the active set
        // changes WITHOUT passing through silence — pure VAD on/offsets are a
        // different error class (missed/FA) and would drown the signal.
        func speakerChanges(_ grid: [Set<String>]) -> [Double] {
            var out: [Double] = []
            guard grid.count > 1 else { return out }
            for i in 1 ..< grid.count
            where grid[i] != grid[i - 1] && !grid[i].isEmpty && !grid[i - 1].isEmpty {
                out.append(Double(i) * frameStep)
            }
            return out
        }
        let refChanges = speakerChanges(refGrid)
        let predChanges = speakerChanges(predGrid)
        var boundaryMAE: Double?
        if !refChanges.isEmpty {
            let cap = 2.0
            let total = refChanges.reduce(0.0) { acc, t in
                acc + min(cap, predChanges.map { abs($0 - t) }.min() ?? cap)
            }
            boundaryMAE = total / Double(refChanges.count)
        }

        // Short-utterance recall: a reference segment < 2.5s counts as recalled
        // when the majority of its frames contain a pred key mapped to its
        // speaker.
        let shortSegments = reference.filter { $0.end - $0.start < 2.5 && $0.end > $0.start }
        var recalled = 0
        for s in shortSegments {
            let i0 = max(0, Int((s.start / frameStep).rounded()))
            let i1 = min(n, Int((s.end / frameStep).rounded()))
            guard i0 < i1 else { continue }
            let correct = (i0 ..< i1).count { i in
                predGrid[i].contains { predToRef[$0] == s.key }
            }
            if Double(correct) >= Double(i1 - i0) * 0.5 { recalled += 1 }
        }

        return Result(
            derSeconds: Double(missed + falseAlarm + confusion) * frameStep,
            missedSeconds: Double(missed) * frameStep,
            falseAlarmSeconds: Double(falseAlarm) * frameStep,
            confusionSeconds: Double(confusion) * frameStep,
            refSpeechSeconds: Double(refSpeech) * frameStep,
            predToRef: predToRef,
            realToPred: realToPred,
            boundaryMAESeconds: boundaryMAE,
            refSpeakerChangeCount: refChanges.count,
            shortUtteranceRecall: shortSegments.isEmpty ? nil : Double(recalled) / Double(shortSegments.count),
            shortUtteranceCount: shortSegments.count,
            purity: predTotal > 0 ? Double(purityHits) / Double(predTotal) : 1,
            coverage: refTotal > 0 ? Double(coverageHits) / Double(refTotal) : 1
        )
    }
}

// MARK: - Vector purity (segment-own-voice, design § 5)

extension DERScorer {
    /// One stored transcript segment with its voice vector.
    struct VectorSegment {
        let start: Double
        let end: Double
        let vector: [Float]
    }

    /// Fraction of segment seconds whose vector is strictly closer to its own
    /// person's meeting voice than to any other person's. The owner is the
    /// reference speaker holding most of the segment's interval; a person's
    /// voice is the seconds-weighted mean of the vectors of segments they own.
    /// Two people sharing one cluster-centroid copy get identical voices — the
    /// tie counts as wrong, which is the point. nil when nothing is owned.
    static func vectorPurity(segments: [VectorSegment], reference: [Segment]) -> Double? {
        var owned: [(seg: VectorSegment, owner: String)] = []
        for s in segments where s.end > s.start {
            var byRef: [String: Double] = [:]
            for r in reference {
                let overlap = min(s.end, r.end) - max(s.start, r.start)
                if overlap > 0 { byRef[r.key, default: 0] += overlap }
            }
            if let owner = byRef.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key {
                owned.append((s, owner))
            }
        }
        guard let dim = owned.first?.seg.vector.count else { return nil }

        var voices: [String: [Float]] = [:]
        for (s, owner) in owned where s.vector.count == dim {
            let w = Float(s.end - s.start)
            var v = voices[owner] ?? [Float](repeating: 0, count: dim)
            for i in 0 ..< dim { v[i] += w * s.vector[i] }
            voices[owner] = v
        }

        var correct = 0.0, total = 0.0
        for (s, owner) in owned where s.vector.count == dim {
            let dur = s.end - s.start
            total += dur
            guard let own = voices[owner] else { continue }
            let ownSim = cosineSimilarity(s.vector, own)
            let beaten = voices.contains { $0.key != owner && cosineSimilarity(s.vector, $0.value) >= ownSim }
            if !beaten { correct += dur }
        }
        return total > 0 ? correct / total : nil
    }
}
