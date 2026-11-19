import Foundation

/// Name-assignment metric (stage2-out-of-pool, решение 2): how much speech the
/// pipeline attached to a speaker record that already existed before the
/// meeting, and whether the record's identity is who actually spoke.
///
/// Confusion can't see this: a lone person given someone else's name is still a
/// unique label inside the meeting (bench M5: one guest under another's record, 40 s,
/// confusion unchanged). A freshly minted `speaker_N` is a new identity, never
/// a wrong name, so only pre-existing records count.
struct NameAssignment {
    struct Result {
        /// Speech seconds on pre-existing records where the reference speaker is the record's identity.
        let rightSeconds: Double
        /// Speech seconds on pre-existing records spoken by someone else.
        let wrongSeconds: Double
        /// Pre-existing records whose dominant reference speaker here is not their identity.
        let falseAssignments: Int
        /// Pre-existing records that received any reference speech here.
        let assignedRecords: Int
    }

    /// - identities: record key → reference speaker it stands for.
    /// - existing: record keys that existed before this meeting was processed.
    static func score(
        predicted: [DERScorer.Segment],
        reference: [DERScorer.Segment],
        identities: [String: String],
        existing: Set<String>
    ) -> Result {
        var right = 0.0
        var wrong = 0.0
        var perRecord: [String: [String: Double]] = [:]
        for p in predicted where existing.contains(p.key) {
            guard let identity = identities[p.key] else { continue }
            for (speaker, sec) in overlapBySpeaker(start: p.start, end: p.end, reference: reference) {
                perRecord[p.key, default: [:]][speaker, default: 0] += sec
                if speaker == identity { right += sec } else { wrong += sec }
            }
        }
        let falseAssignments = perRecord.filter { key, bySpeaker in
            dominant(bySpeaker) != identities[key]
        }.count
        return Result(
            rightSeconds: right,
            wrongSeconds: wrong,
            falseAssignments: falseAssignments,
            assignedRecords: perRecord.count
        )
    }

    /// Reference speaker with the most overlap per predicted key — the identity
    /// a record minted in this meeting carries into later meetings.
    static func dominantSpeakers(predicted: [DERScorer.Segment], reference: [DERScorer.Segment]) -> [String: String] {
        var perKey: [String: [String: Double]] = [:]
        for p in predicted {
            for (speaker, sec) in overlapBySpeaker(start: p.start, end: p.end, reference: reference) {
                perKey[p.key, default: [:]][speaker, default: 0] += sec
            }
        }
        return perKey.compactMapValues(dominant)
    }

    private static func overlapBySpeaker(start: Double, end: Double, reference: [DERScorer.Segment]) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in reference {
            let ov = min(end, r.end) - max(start, r.start)
            if ov > 0 { out[r.key, default: 0] += ov }
        }
        return out
    }

    /// Ties break by name so the result never depends on dictionary order.
    private static func dominant(_ bySpeaker: [String: Double]) -> String? {
        bySpeaker.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
    }
}
