import XCTest

/// The mic-track attribution rule.
/// Its three inputs are pinned here; the third one is where the behaviour changed —
/// several voices without an owner fingerprint used to blanket-assign the whole
/// track to the owner, and now does not.
final class MicAttributionTests: XCTestCase {

    private let owner = "me-id"

    // MARK: - plan (3.1–3.3)

    /// 3.5 / 1.1 — one cluster: the ordinary case still belongs to the owner.
    func testPlan_singleCluster_belongsToOwner() {
        XCTAssertEqual(
            MicAttribution.plan(hasMicAudio: true, distinctClusters: 1),
            .assignWholeTrackToOwner
        )
    }

    /// 3.1 / 1.1 — several clusters: per segment, with or without an owner
    /// fingerprint. The fingerprint no longer gates diarization (2.1) and is
    /// not an input of `plan`, so no blanket assign to the owner either way.
    func testPlan_multipleClusters_perSegment() {
        XCTAssertEqual(
            MicAttribution.plan(hasMicAudio: true, distinctClusters: 3),
            .perSegment
        )
        XCTAssertEqual(
            MicAttribution.plan(hasMicAudio: true, distinctClusters: 2),
            .perSegment
        )
    }

    /// 3.3 — no mic audio: processing ends without assigning anything.
    func testPlan_noMicAudio_skips() {
        XCTAssertEqual(
            MicAttribution.plan(hasMicAudio: false, distinctClusters: 0),
            .skip
        )
    }

    /// Diarization produced nothing at all — not evidence of a second person.
    func testPlan_noClusters_belongsToOwner() {
        XCTAssertEqual(
            MicAttribution.plan(hasMicAudio: true, distinctClusters: 0),
            .assignWholeTrackToOwner
        )
    }

    // MARK: - attribute (3.2, 3.4)

    func testAttribute_matchedLabel_usesDbId() {
        let out = MicAttribution.attribute(
            matchedLabel: "Борис", overlap: 4, ownerIdentifiable: true,
            ownerId: owner, ownerDisplayName: "Захар",
            labelToDbId: ["Борис": "boris-id"]
        )
        XCTAssertEqual(out, .init(speakerId: "boris-id", label: "Борис"))
    }

    /// 2.3 — an unknown voice that cleared the mass floor was minted a
    /// `speaker_N` label by `ClusterLabeler`; it is its own speaker, not the
    /// owner. The db row is created right after, by label.
    func testAttribute_mintedSpeaker_isNotTheOwner() {
        let out = MicAttribution.attribute(
            matchedLabel: "speaker_2", overlap: 3, ownerIdentifiable: true,
            ownerId: owner, ownerDisplayName: "Захар", labelToDbId: [:]
        )
        XCTAssertEqual(out, .init(speakerId: nil, label: "speaker_2"))
    }

    /// 2.3 — too little speech to be a person: `ClusterLabeler` demoted it to
    /// UNKNOWN, and it stays unidentified rather than folding into the owner.
    func testAttribute_unknownWithCoverage_staysUnknown() {
        let out = MicAttribution.attribute(
            matchedLabel: "UNKNOWN", overlap: 2.5, ownerIdentifiable: true,
            ownerId: owner, ownerDisplayName: "Захар", labelToDbId: [:]
        )
        XCTAssertEqual(out, .init(speakerId: nil, label: "UNKNOWN"))
    }

    /// No diarization coverage at all, owner identifiable — his own words.
    func testAttribute_uncovered_withOwnerFingerprint_fallsBackToOwner() {
        let out = MicAttribution.attribute(
            matchedLabel: "UNKNOWN", overlap: 0, ownerIdentifiable: true,
            ownerId: owner, ownerDisplayName: "Захар", labelToDbId: [:]
        )
        XCTAssertEqual(out, .init(speakerId: owner, label: "Захар"))
    }

    /// 3.2 / 3.4 — several voices and no owner fingerprint: nothing is guessed
    /// into the owner's mouth, not even the segments diarization missed.
    func testAttribute_uncovered_withoutOwnerFingerprint_staysUnknown() {
        let out = MicAttribution.attribute(
            matchedLabel: "UNKNOWN", overlap: 0, ownerIdentifiable: false,
            ownerId: owner, ownerDisplayName: "Захар", labelToDbId: [:]
        )
        XCTAssertEqual(out, .init(speakerId: nil, label: "UNKNOWN"))
    }

    // MARK: - ownerLikelySegments

    private func diar(_ start: Double, _ end: Double, _ speaker: String) -> DiarizationService.DiarizationSegment {
        .init(start: start, end: end, speaker: speaker, embedding: [])
    }

    private func reply(_ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(meetingId: "m", speakerLabel: "me", source: .mic, startTime: start, endTime: end, text: "")
    }

    /// Stage-1 clusters: S1 the owner by name, S5 unnamed with the owner as
    /// best candidate, S7 a stranger, S8 an owner-likely scrap left UNKNOWN,
    /// S9 an owner-likely scrap the labeler folded into the stranger.
    private let clusters = ["S1", "S5", "S7", "S8", "S9"]
    private let labels = ["Захар", "speaker_8", "speaker_9", "UNKNOWN", "speaker_9"]

    private func likelyStarts(ownerLikely: Set<String>, labelToDbId: [String: String] = ["Захар": "me-id"]) -> [Double] {
        let times = clusters.indices.map { (Double($0) * 10, Double($0) * 10 + 10) }
        return MicAttribution.ownerLikelySegments(
            times.map { reply($0.0, $0.1) },
            clusters: zip(times, clusters).map { diar($0.0.0, $0.0.1, $0.1) },
            labeled: zip(times, labels).map { diar($0.0.0, $0.0.1, $0.1) },
            ownerLikelyClusters: ownerLikely,
            labelToDbId: labelToDbId
        ).map(\.startTime)
    }

    /// The unnamed voice and the UNKNOWN scrap are the owner's best guess; the
    /// scrap that sounds like the stranger (folded into his label) follows him.
    func testOwnerLikelySegments_unnamedVoiceAndUnknownScrap() {
        XCTAssertEqual(likelyStarts(ownerLikely: ["S5", "S8", "S9"]), [10, 30])
    }

    /// A label bound to a record is somebody the system knows — never a guess.
    func testOwnerLikelySegments_boundLabelIsNotAGuess() {
        XCTAssertEqual(likelyStarts(ownerLikely: ["S5"], labelToDbId: ["speaker_8": "known-id"]), [])
    }

    func testOwnerLikelySegments_noOwnerLikelyClusters_isEmpty() {
        XCTAssertEqual(likelyStarts(ownerLikely: []), [])
    }

    /// A reply goes where most of it lies: 3 s of the unnamed voice against
    /// 7 s of the stranger is the stranger's.
    func testOwnerLikelySegments_followsTheBestOverlap() {
        let out = MicAttribution.ownerLikelySegments(
            [reply(0, 10), reply(10, 20)],
            clusters: [diar(0, 3, "S5"), diar(3, 10, "S7"), diar(10, 17, "S5"), diar(17, 20, "S7")],
            labeled: [diar(0, 3, "speaker_8"), diar(3, 10, "speaker_9"), diar(10, 17, "speaker_8"), diar(17, 20, "speaker_9")],
            ownerLikelyClusters: ["S5"],
            labelToDbId: [:]
        )
        XCTAssertEqual(out.map(\.startTime), [10])
    }
}
