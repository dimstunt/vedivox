import FluidAudio
import XCTest

/// Unit tests for `SegmentRescue` (Stage 2.5).
///
/// Synthetic 4-dim embeddings — the logic is dimension-agnostic. The threshold
/// values mirror the stage-0 separability findings: true speaker ~0.7+, pool
/// lookalike on a foreign voice <0.55.
final class SegmentRescueTests: XCTestCase {

    // MARK: - Fixtures

    private let vecA: [Float] = [1, 0, 0, 0]
    private let vecB: [Float] = [0, 1, 0, 0]
    private let vecC: [Float] = [0, 0, 1, 0]

    private func candidate(
        id: String, name: String, vector: [Float], segmentCount: Int = 100
    ) -> SpeakerMatcher.Candidate {
        SpeakerMatcher.Candidate(
            speakerId: id, displayName: name, canonical: vector, segmentCount: segmentCount
        )
    }

    private func chunk(
        cluster: String, start: Double, end: Double, embedding: [Float]
    ) -> ChunkEmbedding {
        ChunkEmbedding(
            speakerId: cluster, chunkIndex: 0, speakerIndex: 0,
            startTimeSeconds: start, endTimeSeconds: end, embedding256: embedding
        )
    }

    private func segment(
        start: Double, end: Double, label: String?, id: Int64 = 1
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id, meetingId: "m", speakerId: nil, speakerLabel: label,
            source: .system, startTime: start, endTime: end, text: "t",
            originalText: nil, isEdited: false, confidence: nil, embedding: nil
        )
    }

    /// Unit vector between a and b: cos to each ≈ 0.71 — above default accept.
    private func blend(_ a: [Float], _ b: [Float], wa: Float = 1, wb: Float = 1) -> [Float] {
        let raw = zip(a, b).map { wa * $0 + wb * $1 }
        let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return raw.map { $0 / norm }
    }

    // MARK: - planMoves

    func testForeignWindowInsideOwnedClusterMoves() {
        // Cluster S1 owned by A; one window is clearly B's voice.
        let rescue = SegmentRescue()
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S1", start: 0, end: 5, embedding: vecB)],
            clusterOwners: ["S1": "a"],
            pool: [candidate(id: "a", name: "A", vector: vecA), candidate(id: "b", name: "B", vector: vecB)]
        )
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].toSpeakerId, "b")
        XCTAssertEqual(moves[0].fromCluster, "S1")
    }

    func testOwnVoiceStays() {
        let rescue = SegmentRescue()
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S1", start: 0, end: 5, embedding: vecA)],
            clusterOwners: ["S1": "a"],
            pool: [candidate(id: "a", name: "A", vector: vecA), candidate(id: "b", name: "B", vector: vecB)]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    /// The M2/Лука lesson: cluster owner is NOT enrolled (owner sim = 0, margin
    /// can't protect) and a pool lookalike scores below accept — must not move.
    func testUnknownClusterLookalikeBelowAcceptStays() {
        let rescue = SegmentRescue()
        // Voice halfway between B and C with extra off-pool noise: cos to B ≈ 0.5.
        let foreignVoice = blend(blend(vecB, vecC), [0, 0, 0, 1], wa: 1, wb: 1)
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S2", start: 0, end: 5, embedding: foreignVoice)],
            clusterOwners: [:], // S2 stayed speaker_N
            pool: [candidate(id: "b", name: "B", vector: vecB), candidate(id: "c", name: "C", vector: vecC)]
        )
        XCTAssertTrue(moves.isEmpty, "lookalike sim ~0.5 must stay below the accept threshold")
    }

    func testUnknownClusterConfidentMatchMoves() {
        // The lost-speaker case: unmatched cluster, window is clearly B.
        let rescue = SegmentRescue()
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S3", start: 0, end: 5, embedding: vecB)],
            clusterOwners: [:],
            pool: [candidate(id: "b", name: "B", vector: vecB)]
        )
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].toSpeakerId, "b")
    }

    func testShortWindowIgnored() {
        let rescue = SegmentRescue()
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S1", start: 0, end: 1.5, embedding: vecB)],
            clusterOwners: ["S1": "a"],
            pool: [candidate(id: "a", name: "A", vector: vecA), candidate(id: "b", name: "B", vector: vecB)]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    func testMarginGuardAgainstAmbiguity() {
        // Window equidistant between owner A and target B (cos ≈ 0.71 to both):
        // margin guard must block the move.
        let rescue = SegmentRescue()
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S1", start: 0, end: 5, embedding: blend(vecA, vecB))],
            clusterOwners: ["S1": "a"],
            pool: [candidate(id: "a", name: "A", vector: vecA), candidate(id: "b", name: "B", vector: vecB)]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    /// The lesson of one weekly meeting: an ambiguousMargin cluster (no owner) whose windows are
    /// all one voice sits closer to its own centroid than to any lookalike
    /// canonical — rescue must not tear it apart.
    func testHomogeneousUnownedClusterStays() {
        let rescue = SegmentRescue()
        let voice = blend(vecA, vecB, wa: 3, wb: 2) // cluster centroid, cos to B ≈ 0.55
        let window = blend(voice, vecB, wa: 1, wb: 0.25) // cos to B ≈ 0.70 (≥ accept), to centroid ≈ 0.98
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S4", start: 0, end: 5, embedding: window)],
            clusterOwners: [:],
            pool: [candidate(id: "b", name: "B", vector: vecB)],
            clusterCentroids: ["S4": voice]
        )
        XCTAssertTrue(moves.isEmpty, "window is the cluster's own voice, not B's")
    }

    /// A glued cluster: a stretch of B inside an unowned cluster of someone else
    /// is far from the cluster centroid and still moves.
    func testForeignStretchInUnownedClusterMoves() {
        let rescue = SegmentRescue()
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S4", start: 0, end: 5, embedding: vecB)],
            clusterOwners: [:],
            pool: [candidate(id: "b", name: "B", vector: vecB)],
            clusterCentroids: ["S4": blend(vecC, vecB, wa: 3, wb: 1)]
        )
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].toSpeakerId, "b")
    }

    func testLowDataCanonicalNotATarget() {
        let rescue = SegmentRescue()
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S1", start: 0, end: 5, embedding: vecB)],
            clusterOwners: ["S1": "a"],
            pool: [
                candidate(id: "a", name: "A", vector: vecA),
                candidate(id: "b", name: "B", vector: vecB, segmentCount: 3), // below floor
            ]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    // MARK: - apply

    func testApplyRelabelsCoveredSegment() {
        let rescue = SegmentRescue()
        let moves = [SegmentRescue.Move(
            start: 0, end: 10, fromCluster: "S1", toSpeakerId: "b",
            toDisplayName: "B", confidence: 0.8, embedding: vecB
        )]
        let segments = [
            segment(start: 1, end: 4, label: "A", id: 1), // fully inside the window
            segment(start: 20, end: 25, label: "A", id: 2), // outside
        ]
        let out = rescue.apply(moves: moves, to: segments)
        XCTAssertEqual(out.segments[0].speakerLabel, "B")
        XCTAssertNil(out.segments[0].speakerId)
        XCTAssertEqual(out.segments[0].embedding, Speaker.encodeEmbedding(vecB))
        XCTAssertEqual(out.segments[1].speakerLabel, "A")
        XCTAssertEqual(out.labelToDbId, ["B": "b"])
        XCTAssertEqual(out.movedSeconds, 3.0, accuracy: 0.001)
    }

    func testApplyLeavesPartiallyCoveredSegment() {
        let rescue = SegmentRescue()
        let moves = [SegmentRescue.Move(
            start: 0, end: 2, fromCluster: "S1", toSpeakerId: "b",
            toDisplayName: "B", confidence: 0.8, embedding: vecB
        )]
        // Only 2 of 10 seconds covered — below minSegmentCoverage 0.5.
        let out = rescue.apply(moves: moves, to: [segment(start: 0, end: 10, label: "A")])
        XCTAssertEqual(out.segments[0].speakerLabel, "A")
        XCTAssertEqual(out.movedSeconds, 0)
    }

    /// stage2-out-of-pool: «Катя» is already record a here; a line moved to a
    /// different record named «Катя» gets «Катя (2)», not a's label.
    func testApplyToNamesakeGetsDistinctLabel() {
        let rescue = SegmentRescue()
        let moves = [SegmentRescue.Move(
            start: 0, end: 10, fromCluster: "S1", toSpeakerId: "katya-b",
            toDisplayName: "Катя", confidence: 0.8, embedding: vecB
        )]
        let segments = [
            segment(start: 1, end: 4, label: "speaker_1", id: 1),
            segment(start: 20, end: 25, label: "Катя", id: 2),
        ]
        let out = rescue.apply(moves: moves, to: segments, boundLabels: ["Катя": "katya-a"])
        XCTAssertEqual(out.segments[0].speakerLabel, "Катя (2)")
        XCTAssertEqual(out.segments[1].speakerLabel, "Катя")
        XCTAssertEqual(out.labelToDbId, ["Катя (2)": "katya-b"])
    }

    /// A move to a confirmed record named `speaker_1` must not land on the
    /// fresh `speaker_1` this meeting minted for a stranger.
    func testApplyAutoLabelTargetSkipsFreshMint() {
        let rescue = SegmentRescue()
        let moves = [SegmentRescue.Move(
            start: 0, end: 10, fromCluster: "S2", toSpeakerId: "old-speaker-1",
            toDisplayName: "speaker_1", confidence: 0.8, embedding: vecB
        )]
        let segments = [
            segment(start: 1, end: 4, label: "speaker_2", id: 1),
            segment(start: 20, end: 25, label: "speaker_1", id: 2), // fresh mint, unbound
        ]
        let out = rescue.apply(moves: moves, to: segments)
        XCTAssertEqual(out.segments[0].speakerLabel, "speaker_3")
        XCTAssertEqual(out.labelToDbId, ["speaker_3": "old-speaker-1"])
    }

    // MARK: - Ownerless guards (stage2-dead-zone)

    /// A window of a cluster that exists only among the windows (no segments,
    /// mass 0) never moves — the recording-tail case that fed an outlier profile.
    func testOwnerlessMicroClusterGivesAwayNothing() {
        let rescue = SegmentRescue()
        let moves = rescue.planMoves(
            chunks: [
                chunk(cluster: "S1", start: 0, end: 10, embedding: vecA),
                chunk(cluster: "S2", start: 10, end: 20, embedding: vecB),
                chunk(cluster: "S1", start: 20, end: 60, embedding: vecA),
            ],
            clusterOwners: [:],
            pool: [candidate(id: "b", name: "B", vector: vecB)],
            clusterCentroids: ["S1": vecA, "S2": vecC],
            clusterMass: ["S1": 50]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    /// The last windows of an ownerless cluster stay put even when it is big.
    func testOwnerlessWindowAtTrackTailStays() {
        let rescue = SegmentRescue()
        let pool = [candidate(id: "b", name: "B", vector: vecB)]
        let chunks = [
            chunk(cluster: "S1", start: 0, end: 10, embedding: vecB),    // mid-track: moves
            chunk(cluster: "S1", start: 10, end: 50, embedding: vecA),
            chunk(cluster: "S1", start: 50, end: 58, embedding: vecB),   // ends in the last 5 s: stays
        ]
        let moves = rescue.planMoves(
            chunks: chunks, clusterOwners: [:], pool: pool,
            clusterCentroids: ["S1": vecA], clusterMass: ["S1": 58]
        )
        XCTAssertEqual(moves.map(\.start), [0])
    }

    /// Owned clusters keep the behavior, tail or not.
    func testOwnedClusterTailStillMoves() {
        let rescue = SegmentRescue()
        let pool = [candidate(id: "a", name: "A", vector: vecA), candidate(id: "b", name: "B", vector: vecB)]
        let moves = rescue.planMoves(
            chunks: [chunk(cluster: "S1", start: 0, end: 50, embedding: vecA),
                     chunk(cluster: "S1", start: 50, end: 58, embedding: vecB)],
            clusterOwners: ["S1": "a"], pool: pool,
            clusterCentroids: ["S1": vecA], clusterMass: ["S1": 58]
        )
        XCTAssertEqual(moves.map(\.toSpeakerId), ["b"])
    }

    /// segment-own-voice § 3: a moved segment carries the mean of the target's
    /// windows over it, not the single best window.
    func testApplyWritesMeanOfTargetWindows() throws {
        let rescue = SegmentRescue()
        let moves = [
            SegmentRescue.Move(start: 0, end: 5, fromCluster: "S1", toSpeakerId: "b",
                               toDisplayName: "B", confidence: 0.8, embedding: vecB),
            SegmentRescue.Move(start: 5, end: 10, fromCluster: "S1", toSpeakerId: "b",
                               toDisplayName: "B", confidence: 0.8, embedding: vecC),
        ]
        let out = rescue.apply(moves: moves, to: [segment(start: 3, end: 7, label: "A")])
        let v = Speaker.decodeEmbedding(try XCTUnwrap(out.segments[0].embedding))
        let half = Float(0.5).squareRoot()
        XCTAssertEqual(v[1], half, accuracy: 1e-5)
        XCTAssertEqual(v[2], half, accuracy: 1e-5)
    }
}
