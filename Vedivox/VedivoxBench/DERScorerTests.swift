import XCTest

/// Unit tests for the overlap-aware DER scorer. Pure synthetic
/// segments — no audio, no pipeline, runs in milliseconds:
///
///     xcodebuild test -project Vedivox/Vedivox.xcodeproj -scheme VedivoxBench \
///       -only-testing:VedivoxBench/DERScorerTests
final class DERScorerTests: XCTestCase {
    private let scorer = DERScorer(frameStep: 0.01)

    private func seg(_ start: Double, _ end: Double, _ key: String) -> DERScorer.Segment {
        DERScorer.Segment(start: start, end: end, key: key)
    }

    func testPerfectMatchIsZeroDER() {
        let result = scorer.score(
            predicted: [seg(0, 10, "x")],
            reference: [seg(0, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.derSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.refSpeechSeconds, 10, accuracy: 0.011)
        XCTAssertEqual(result.predToRef["x"], "A")
        XCTAssertEqual(result.realToPred["A"], "x")
    }

    /// The motivating case: a second pred speaker OVERLAPPING the
    /// mapped one must score as false alarm, not confusion. The old single-label
    /// grid collapsed frames 5–10 to last-writer "y" → 5s of phantom confusion.
    func testOverlappingPredIsFalseAlarmNotConfusion() {
        let result = scorer.score(
            predicted: [seg(0, 10, "x"), seg(5, 10, "y")],
            reference: [seg(0, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.confusionSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.falseAlarmSeconds, 5, accuracy: 0.011)
        XCTAssertEqual(result.missedSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.realToPred["A"], "x")
    }

    /// Two ref speakers talking simultaneously, only one covered by pred:
    /// the uncovered one is missed speech (md-eval counts speaker-seconds).
    func testOverlappingRefCountsMissedSpeakerSeconds() {
        let result = scorer.score(
            predicted: [seg(0, 10, "x")],
            reference: [seg(0, 10, "A"), seg(5, 10, "B")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.missedSeconds, 5, accuracy: 0.011)
        XCTAssertEqual(result.falseAlarmSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.confusionSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.refSpeechSeconds, 15, accuracy: 0.011)
    }

    /// Overlap on BOTH sides resolves cleanly when the pairs match.
    func testMatchedOverlapOnBothSidesIsZeroDER() {
        let result = scorer.score(
            predicted: [seg(0, 10, "x"), seg(5, 10, "y")],
            reference: [seg(0, 10, "A"), seg(5, 10, "B")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.derSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.refSpeechSeconds, 15, accuracy: 0.011)
    }

    func testUnmappedPredOverRefIsConfusion() {
        // x dominates A (6s) and takes the mapping; y co-occurs with A for 4s
        // but stays unmapped → those 4s are confusion.
        let result = scorer.score(
            predicted: [seg(0, 6, "x"), seg(6, 10, "y")],
            reference: [seg(0, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.predToRef["x"], "A")
        XCTAssertNil(result.predToRef["y"])
        XCTAssertEqual(result.confusionSeconds, 4, accuracy: 0.011)
        XCTAssertEqual(result.missedSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.falseAlarmSeconds, 0, accuracy: 0.011)
    }

    func testMissedAndFalseAlarmOutsideOverlap() {
        let result = scorer.score(
            predicted: [seg(0, 4, "x"), seg(12, 14, "x")],
            reference: [seg(0, 8, "A")],
            windowLengthSeconds: 20
        )
        XCTAssertEqual(result.missedSeconds, 4, accuracy: 0.011)
        XCTAssertEqual(result.falseAlarmSeconds, 2, accuracy: 0.011)
        XCTAssertEqual(result.confusionSeconds, 0, accuracy: 0.011)
    }

    /// Greedy mapping is injective: when one pred dominates two refs, the second
    /// ref must be picked up by the next-best pred, not double-assigned. The
    /// 6–10 stretch has 2 pred speakers vs 1 ref → the excess is false alarm.
    func testInjectiveMapping() {
        let result = scorer.score(
            predicted: [seg(0, 10, "x"), seg(6, 10, "y")],
            reference: [seg(0, 6, "A"), seg(6, 10, "B")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.predToRef["x"], "A")
        XCTAssertEqual(result.predToRef["y"], "B")
        XCTAssertEqual(result.missedSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.confusionSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.falseAlarmSeconds, 4, accuracy: 0.011)
    }

    /// Same-speaker overlapping segments (legal in gt.json) must not double-count.
    func testSameKeyOverlapDeduplicates() {
        let result = scorer.score(
            predicted: [seg(0, 10, "x")],
            reference: [seg(0, 7, "A"), seg(4, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.refSpeechSeconds, 10, accuracy: 0.011)
        XCTAssertEqual(result.derSeconds, 0, accuracy: 0.011)
    }

    func testSegmentsClampedToWindow() {
        let result = scorer.score(
            predicted: [seg(-5, 12, "x")],
            reference: [seg(0, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.derSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.falseAlarmSeconds, 0, accuracy: 0.011)
    }

    func testEmptyPredIsAllMissed() {
        let result = scorer.score(
            predicted: [],
            reference: [seg(0, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.missedSeconds, 10, accuracy: 0.011)
        XCTAssertTrue(result.predToRef.isEmpty)
        XCTAssertTrue(result.realToPred.isEmpty)
    }

    /// realToPred picks the pred key with the most co-occurring speaker-frames.
    // MARK: - Tier-1 metrics (boundary MAE, short-utterance recall)

    func testBoundaryMAEMeasuresDrift() throws {
        // Ref change A→B at t=5; pred change at t=6 — MAE 1.0s.
        let result = scorer.score(
            predicted: [seg(0, 6, "x"), seg(6, 10, "y")],
            reference: [seg(0, 5, "A"), seg(5, 10, "B")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.refSpeakerChangeCount, 1)
        XCTAssertEqual(try XCTUnwrap(result.boundaryMAESeconds), 1.0, accuracy: 0.02)
    }

    func testBoundaryMAEIgnoresSilenceOnsets() {
        // Speech → silence → speech by the SAME speaker: no speaker change.
        let result = scorer.score(
            predicted: [seg(0, 4, "x"), seg(6, 10, "x")],
            reference: [seg(0, 4, "A"), seg(6, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.refSpeakerChangeCount, 0)
        XCTAssertNil(result.boundaryMAESeconds)
    }

    func testShortUtteranceRecallCountsDissolvedInterjection() throws {
        // B's 1.2s interjection inside A's stretch: pred dissolves it into "x"
        // (mapped to A) → recall 0 of 1.
        let dissolved = scorer.score(
            predicted: [seg(0, 10, "x")],
            reference: [seg(0, 5, "A"), seg(5, 6.2, "B"), seg(6.2, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(dissolved.shortUtteranceCount, 1)
        XCTAssertEqual(try XCTUnwrap(dissolved.shortUtteranceRecall), 0.0, accuracy: 0.001)

        // Same scenario but pred carves the interjection out for "y" → 1 of 1.
        let recalled = scorer.score(
            predicted: [seg(0, 5, "x"), seg(5, 6.2, "y"), seg(6.2, 10, "x")],
            reference: [seg(0, 5, "A"), seg(5, 6.2, "B"), seg(6.2, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(try XCTUnwrap(recalled.shortUtteranceRecall), 1.0, accuracy: 0.001)
    }

    /// Lookalike merge: two people in one pred cluster → purity 0.6, coverage 1,
    /// and the smaller person's seconds are confusion.
    func testMergeLowersPurityNotCoverage() {
        let result = scorer.score(
            predicted: [seg(0, 10, "x")],
            reference: [seg(0, 6, "A"), seg(6, 10, "B")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.purity, 0.6, accuracy: 0.002)
        XCTAssertEqual(result.coverage, 1.0, accuracy: 0.002)
        XCTAssertEqual(result.confusionSeconds, 4, accuracy: 0.011)
    }

    /// ±0.25s collar drops the frames around every reference boundary: a pred
    /// boundary 0.2s late costs nothing, and those frames leave ref speech.
    func testCollarForgivesBoundaryJitter() {
        let result = scorer.score(
            predicted: [seg(0, 5.2, "x"), seg(5.2, 10, "y")],
            reference: [seg(0, 5, "A"), seg(5, 10, "B")],
            windowLengthSeconds: 10,
            collarSeconds: 0.25
        )
        XCTAssertEqual(result.derSeconds, 0, accuracy: 0.011)
        XCTAssertEqual(result.refSpeechSeconds, 10 - 4 * 0.25, accuracy: 0.011)
    }

    func testRealToPredPicksDominantPred() {
        let result = scorer.score(
            predicted: [seg(0, 3, "y"), seg(3, 10, "x")],
            reference: [seg(0, 10, "A")],
            windowLengthSeconds: 10
        )
        XCTAssertEqual(result.realToPred["A"], "x")
    }
}

/// `vector_purity` (segment-own-voice, design § 5) on synthetic vectors.
final class VectorPurityTests: XCTestCase {
    private func vs(_ start: Double, _ end: Double, _ v: [Float]) -> DERScorer.VectorSegment {
        DERScorer.VectorSegment(start: start, end: end, vector: v)
    }

    private let reference = [
        DERScorer.Segment(start: 0, end: 10, key: "A"),
        DERScorer.Segment(start: 10, end: 20, key: "B"),
    ]

    /// Centroid copies: both people carry one vector → a tie → 0.
    func testSameVectorsScoreZero() throws {
        let shared: [Float] = [1, 0]
        let purity = try XCTUnwrap(DERScorer.vectorPurity(
            segments: [vs(0, 10, shared), vs(10, 20, shared)], reference: reference
        ))
        XCTAssertEqual(purity, 0, accuracy: 1e-9)
    }

    /// Own vectors: each segment sits on its own person's voice → 1.
    func testDistinctVectorsScoreOne() throws {
        let purity = try XCTUnwrap(DERScorer.vectorPurity(
            segments: [vs(0, 5, [1, 0]), vs(5, 10, [0.9, 0.1]), vs(10, 20, [0, 1])],
            reference: reference
        ))
        XCTAssertEqual(purity, 1, accuracy: 1e-9)
    }

    /// Weighted by seconds: a 2 s segment of A carrying B's voice costs 2 of 20 s.
    func testWrongSegmentCostsItsSeconds() throws {
        let purity = try XCTUnwrap(DERScorer.vectorPurity(
            segments: [vs(0, 8, [1, 0]), vs(8, 10, [0, 1]), vs(10, 20, [0, 1])],
            reference: reference
        ))
        XCTAssertEqual(purity, 0.9, accuracy: 1e-9)
    }
}
