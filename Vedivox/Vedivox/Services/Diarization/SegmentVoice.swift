import FluidAudio
import Foundation

/// A segment's own voice vector (segment-own-voice).
///
/// The offline diarizer stamps every segment with a copy of its cluster
/// centroid, which makes everything after Stage 1 blind to what a cluster is
/// made of: two people merged into one cluster carry one vector. The chunk
/// windows WeSpeaker already computed cover every moment of speech with up to
/// five vectors of its own cluster; a segment's voice is their mean.
enum SegmentVoice {
    struct Timed {
        let start: Double
        let end: Double
        let vector: [Float]
    }

    /// Mean of the unit-length `sources` overlapping [start, end], weighted by
    /// overlap seconds, L2-normalized. Nothing overlaps → the nearest source in
    /// time (`overlapped == false`). nil when there is no usable source.
    static func vector(start: Double, end: Double, from sources: [Timed]) -> (vector: [Float], overlapped: Bool)? {
        guard let dim = sources.first(where: { !$0.vector.isEmpty })?.vector.count else { return nil }
        let usable = sources.filter { $0.vector.count == dim }

        var sum = [Float](repeating: 0, count: dim)
        var weight = 0.0
        for s in usable {
            let overlap = min(end, s.end) - max(start, s.start)
            guard overlap > 0 else { continue }
            let unit = l2Normalize(s.vector)
            for i in 0 ..< dim { sum[i] += Float(overlap) * unit[i] }
            weight += overlap
        }
        if weight > 0 { return (l2Normalize(sum), true) }

        let nearest = usable.min { distance($0, start, end) < distance($1, start, end) }
        return nearest.map { (l2Normalize($0.vector), false) }
    }

    /// Replace each segment's centroid copy with the mean of its own cluster's
    /// windows (design § 1). Windows shorter than `minWindowSeconds` are too
    /// unreliable — the rescue threshold. A cluster with no usable window keeps
    /// the centroid. The centroid stays on the segment as `clusterEmbedding`.
    static func ownVectors(
        _ segments: [DiarizationService.DiarizationSegment],
        chunks: [ChunkEmbedding],
        minWindowSeconds: Double = SegmentRescue.Config.default.minWindowSeconds
    ) -> (segments: [DiarizationService.DiarizationSegment], nearestWindow: Int, centroid: Int) {
        let windows = Dictionary(
            grouping: chunks.filter { $0.endTimeSeconds - $0.startTimeSeconds >= minWindowSeconds },
            by: \.speakerId
        ).mapValues { $0.map { Timed(start: $0.startTimeSeconds, end: $0.endTimeSeconds, vector: $0.embedding256) } }

        var nearestWindow = 0
        var centroid = 0
        let out = segments.map { seg in
            let own = vector(start: seg.start, end: seg.end, from: windows[seg.speaker] ?? [])
            if own == nil { centroid += 1 } else if own?.overlapped == false { nearestWindow += 1 }
            return DiarizationService.DiarizationSegment(
                start: seg.start,
                end: seg.end,
                speaker: seg.speaker,
                embedding: own?.vector ?? seg.embedding,
                clusterEmbedding: seg.embedding
            )
        }
        return (out, nearestWindow, centroid)
    }

    private static func distance(_ s: Timed, _ start: Double, _ end: Double) -> Double {
        max(s.start - end, start - s.end)
    }

    private static func l2Normalize(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
}
