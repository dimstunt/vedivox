import Foundation

/// Mic-track attribution rules, lifted out of `TranscriptionPipeline` so they
/// can be exercised without audio, a diarizer or a database. The pipeline owns
/// the I/O; this type owns the decisions.
///
/// Recognition and display are separate questions (`foreign-voices-on-mic`,
/// решение 1): nothing here consults a mode or a setting. The mic track is
/// diarized whenever there is audio, and every voice it tells apart goes
/// through ordinary attribution.
enum MicAttribution {

    /// What to do with the mic track once diarization has had its say.
    enum Plan: Equatable {
        /// No mic audio — nothing to attribute.
        case skip
        /// One discernible voice on the track — it is the owner's.
        case assignWholeTrackToOwner
        /// Several voices — attribute segment by segment.
        case perSegment
    }

    /// - `distinctClusters`: voices diarization told apart. 0 means it produced
    ///   nothing (or failed), which is not evidence of a second person — the
    ///   ordinary single-voice answer stands.
    static func plan(hasMicAudio: Bool, distinctClusters: Int) -> Plan {
        guard hasMicAudio else { return .skip }
        return distinctClusters >= 2 ? .perSegment : .assignWholeTrackToOwner
    }

    /// Where one transcript segment lands, given its best diarization match.
    struct Attribution: Equatable {
        var speakerId: String?
        var label: String
    }

    /// `ownerIdentifiable`: the owner has a canonical embedding in the active
    /// diarizer's space, so diarization could route his own voice back to him.
    /// Without one we do not guess him — false authorship is worse than a
    /// missing name, because the first is invisible and the second is not.
    static func attribute(
        matchedLabel: String,
        overlap: Double,
        ownerIdentifiable: Bool,
        ownerId: String,
        ownerDisplayName: String,
        labelToDbId: [String: String]
    ) -> Attribution {
        guard matchedLabel == "UNKNOWN" else {
            // A freshly minted `speaker_N` has no db row yet — nil is honest,
            // and `createSpeakersFromDiarization` fills it in by label.
            return Attribution(speakerId: labelToDbId[matchedLabel], label: matchedLabel)
        }
        // A demoted micro-cluster WITH diarization coverage is genuinely
        // "we don't know who this is". Only segments diarization never covered
        // at all default to the owner, and only when he is identifiable.
        return overlap == 0 && ownerIdentifiable
            ? Attribution(speakerId: ownerId, label: ownerDisplayName)
            : Attribution(speakerId: nil, label: "UNKNOWN")
    }

    /// Mic replies spoken by a voice the matcher left unnamed although the
    /// owner was its best candidate — the ones the foreign-voice
    /// rule must leave alone. `clusters` are the diarization segments under
    /// their Stage-1 ids, `labeled` the same segments after `ClusterLabeler`.
    ///
    /// A label bound to a record is somebody the system knows, and a label a
    /// non-owner-likely cluster carries too (a scrap folded into a stranger)
    /// follows that voice: neither is a guess in the owner's favour.
    static func ownerLikelySegments(
        _ micSegments: [TranscriptSegment],
        clusters: [DiarizationService.DiarizationSegment],
        labeled: [DiarizationService.DiarizationSegment],
        ownerLikelyClusters: Set<String>,
        labelToDbId: [String: String]
    ) -> [TranscriptSegment] {
        guard !ownerLikelyClusters.isEmpty, clusters.count == labeled.count else { return [] }
        let pairs = zip(clusters, labeled)
        let strangerLabels = Set(
            pairs.filter { !ownerLikelyClusters.contains($0.0.speaker) && $0.1.speaker != "UNKNOWN" }.map(\.1.speaker)
        )
        let voice = pairs.filter {
            ownerLikelyClusters.contains($0.0.speaker)
                && labelToDbId[$0.1.speaker] == nil
                && !strangerLabels.contains($0.1.speaker)
        }.map(\.1)
        guard !voice.isEmpty else { return [] }
        // Same rule as attribution: a reply goes to the segment it overlaps most.
        return micSegments.filter { segment in
            let own = TranscriptMerger.findBestMatch(start: segment.startTime, end: segment.endTime, diarization: voice)
            let best = TranscriptMerger.findBestMatch(start: segment.startTime, end: segment.endTime, diarization: labeled)
            return own.overlap > 0 && own.overlap >= best.overlap
        }
    }
}
