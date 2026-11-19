import XCTest

/// Unit tests for `SpeakerMatcher` (Stage 2 of two-stage diarization).
///
/// Use synthetic 4-dimensional embeddings for clarity — the production pipeline
/// uses 256 dims but the matcher's behaviour is dimension-agnostic.
final class SpeakerMatcherTests: XCTestCase {

    // MARK: - Test fixtures (synthetic candidates)

    /// Build a candidate aligned with the given unit vector. `segmentCount` defaults
    /// above the matcher's filter threshold so candidates pass by default.
    private func candidate(
        id: String, name: String, vector: [Float], segmentCount: Int = 100
    ) -> SpeakerMatcher.Candidate {
        SpeakerMatcher.Candidate(
            speakerId: id,
            displayName: name,
            canonical: vector,
            segmentCount: segmentCount
        )
    }

    /// Three orthogonal candidates Alice/Bob/Carol, each with plenty of segments.
    private var orthogonalPool: [SpeakerMatcher.Candidate] {
        [
            candidate(id: "alice-id", name: "Alice", vector: [1, 0, 0, 0]),
            candidate(id: "bob-id", name: "Bob", vector: [0, 1, 0, 0]),
            candidate(id: "carol-id", name: "Carol", vector: [0, 0, 1, 0]),
        ]
    }

    // MARK: - Basic match / abstain logic

    /// A centroid that points exactly at one candidate must produce a confident
    /// match with sim ≈ 1.0 and a wide margin to the orthogonal alternatives.
    func testConfidentMatchOnExactDirection() {
        let matcher = SpeakerMatcher()
        let result = matcher.match(clusterCentroid: [1, 0, 0, 0], pool: orthogonalPool)
        guard case .matched(let id, let name, let confidence) = result else {
            XCTFail("expected .matched, got \(result)")
            return
        }
        XCTAssertEqual(id, "alice-id")
        XCTAssertEqual(name, "Alice")
        XCTAssertEqual(confidence, 1.0, accuracy: 1e-5)
    }

    /// A centroid roughly halfway between two candidates triggers the margin guard.
    /// `(top1 - top2)` is below the default 0.05 → matcher abstains rather than
    /// silently picking one.
    func testAmbiguousMarginCausesAbstain() {
        let matcher = SpeakerMatcher()
        // Slightly closer to Alice than Bob, but only by ~0.014.
        let centroid: [Float] = [0.71, 0.70, 0, 0]
        let result = matcher.match(clusterCentroid: centroid, pool: orthogonalPool)
        guard case .unmatched(let reason) = result else {
            XCTFail("expected .unmatched, got \(result)")
            return
        }
        guard case .ambiguousMargin(let topSim, let margin, let topName, let runnerUp) = reason else {
            XCTFail("expected .ambiguousMargin, got \(reason)")
            return
        }
        XCTAssertGreaterThan(topSim, 0.5, "top sim should still be high in this scenario")
        XCTAssertLessThan(margin, 0.05, "margin should be below default threshold")
        XCTAssertTrue([topName, runnerUp].contains("Alice"))
        XCTAssertTrue([topName, runnerUp].contains("Bob"))
    }

    /// A centroid orthogonal to the entire pool produces low similarity to all
    /// candidates and abstains via the `lowSimilarity` reason.
    func testLowSimilarityCausesAbstain() {
        let matcher = SpeakerMatcher()
        // Direction not covered by any candidate — sim to all is 0.
        let result = matcher.match(clusterCentroid: [0, 0, 0, 1], pool: orthogonalPool)
        guard case .unmatched(let reason) = result else {
            XCTFail("expected .unmatched, got \(result)")
            return
        }
        guard case .lowSimilarity(let topSim, _) = reason else {
            XCTFail("expected .lowSimilarity, got \(reason)")
            return
        }
        XCTAssertLessThan(topSim, 0.55)
    }

    /// Empty enrollment pool always abstains with `.emptyPool` regardless of
    /// centroid. This is the bootstrap case (no enrolled speakers yet).
    func testEmptyPoolAbstains() {
        let matcher = SpeakerMatcher()
        let result = matcher.match(clusterCentroid: [1, 0, 0, 0], pool: [])
        XCTAssertEqual(result, .unmatched(reason: .emptyPool))
    }

    // MARK: - Min-segments filter

    /// Candidates with `segmentCount < minSegmentsForCanonical` must be filtered
    /// out before matching. This defends against low-data canonicals that score
    /// high to unrelated voices (real failure mode: a speaker with 3
    /// segments was scoring 0.70 against a different speaker's audio).
    func testLowSegmentCandidatesFilteredOut() {
        let matcher = SpeakerMatcher() // default minSegmentsForCanonical = 5
        let pool: [SpeakerMatcher.Candidate] = [
            // Aligned with the centroid, but only 3 segments — must be filtered.
            candidate(id: "noisy", name: "Noisy3", vector: [1, 0, 0, 0], segmentCount: 3),
            // Orthogonal, well-enrolled candidate.
            candidate(id: "stable", name: "StableBob", vector: [0, 1, 0, 0], segmentCount: 50),
        ]
        let result = matcher.match(clusterCentroid: [1, 0, 0, 0], pool: pool)
        // Noisy3 would have been a perfect match if not filtered. Filter must drop
        // it, leaving only StableBob (orthogonal → low sim). Expect abstain.
        guard case .unmatched = result else {
            XCTFail("Low-data candidate must be filtered out; expected abstain, got \(result)")
            return
        }
    }

    /// If every candidate is below the segment-count floor, the pool is empty.
    func testAllLowSegmentMeansEmptyPool() {
        let matcher = SpeakerMatcher()
        let pool: [SpeakerMatcher.Candidate] = [
            candidate(id: "a", name: "A", vector: [1, 0, 0, 0], segmentCount: 2),
            candidate(id: "b", name: "B", vector: [0, 1, 0, 0], segmentCount: 4),
        ]
        let result = matcher.match(clusterCentroid: [1, 0, 0, 0], pool: pool)
        XCTAssertEqual(result, .unmatched(reason: .emptyPool))
    }

    // MARK: - Threshold tuning

    /// Custom thresholds propagate into the decision logic.
    func testCustomThresholdsApplied() {
        // Stricter accept (0.95) — even a fairly close direction won't match.
        let matcher = SpeakerMatcher(config: SpeakerMatcher.Config(
            acceptThreshold: 0.95,
            marginThreshold: 0.05,
            minSegmentsForCanonical: 5
        ))
        let pool: [SpeakerMatcher.Candidate] = [
            candidate(id: "a", name: "A", vector: [1, 0, 0, 0]),
            candidate(id: "b", name: "B", vector: [0, 1, 0, 0]),
        ]
        // Sim 0.866 to A — would match under default 0.55, must abstain under 0.95.
        let centroid: [Float] = [0.866, 0.5, 0, 0]
        let result = matcher.match(clusterCentroid: centroid, pool: pool)
        guard case .unmatched(let reason) = result else {
            XCTFail("expected abstain under strict accept threshold, got \(result)")
            return
        }
        if case .lowSimilarity = reason { /* ok */ } else {
            XCTFail("expected .lowSimilarity reason, got \(reason)")
        }
    }

    // MARK: - Batch matching

    /// `matchAll` returns one resolution per cluster id, preserving keys.
    func testMatchAllOverMultipleClusters() {
        let matcher = SpeakerMatcher()
        let centroids: [String: [Float]] = [
            "1": [1, 0, 0, 0], // exact Alice
            "2": [0, 1, 0, 0], // exact Bob
            "3": [0, 0, 0, 1], // orthogonal — abstain
            "4": [0.71, 0.70, 0, 0], // ambiguous Alice/Bob — abstain
        ]
        let results = matcher.matchAll(clusterCentroids: centroids, pool: orthogonalPool)
        XCTAssertEqual(results.count, 4)

        if case .matched(_, let n1, _) = results["1"]! { XCTAssertEqual(n1, "Alice") } else {
            XCTFail("cluster 1 should match Alice")
        }

        if case .matched(_, let n2, _) = results["2"]! { XCTAssertEqual(n2, "Bob") } else {
            XCTFail("cluster 2 should match Bob")
        }

        if case .unmatched = results["3"]! { /* ok */ } else { XCTFail("cluster 3 should abstain") }
        if case .unmatched = results["4"]! { /* ok */ } else { XCTFail("cluster 4 should abstain") }
    }

    // MARK: - Dead zone (stage2-dead-zone)

    /// `segments` seconds of one cluster, every segment carrying `embedding`
    /// (offline path: segments are copies of the centroid).
    private func cluster(seconds: Double, embedding: [Float]) -> [DiarizationService.DiarizationSegment] {
        stride(from: 0.0, to: seconds, by: 2.0).map {
            DiarizationService.DiarizationSegment(start: $0, end: min($0 + 2, seconds), speaker: "S1", embedding: embedding)
        }
    }

    /// Bench M5: a newcomer at 0.557 to Нина's canonical with a wide margin —
    /// a name under 0.55/0.05, a `speaker_N` under the default dead zone.
    func testDeadZoneKeepsNewcomerAnonymous() {
        let sim: Float = 0.557
        let centroid: [Float] = [sim, (1 - sim * sim).squareRoot(), 0, 0]
        let pool = [candidate(id: "nina-id", name: "Нина", vector: [1, 0, 0, 0])]

        let result = SpeakerMatcher().matchAllWithAffinity(
            clusterToSegments: ["S1": cluster(seconds: 60, embedding: centroid)], pool: pool
        )["S1"]
        guard case .unmatched(.lowSimilarity(let top, let name)) = result else {
            return XCTFail("expected lowSimilarity, got \(String(describing: result))")
        }
        XCTAssertEqual(top, sim, accuracy: 1e-4)
        XCTAssertEqual(name, "Нина")
        // The old thresholds took it: this is the flip the dead zone removes.
        let old = SpeakerMatcher(config: .init(acceptThreshold: 0.55, marginThreshold: 0.05, minSegmentsForCanonical: 5)).matchAllWithAffinity(
            clusterToSegments: ["S1": cluster(seconds: 60, embedding: centroid)], pool: pool
        )["S1"]
        guard case .matched = old else { return XCTFail("old thresholds should match, got \(String(describing: old))") }
    }

    /// Margin 0.10: 0.72 vs 0.64 is ambiguous now (was a name at 0.05).
    func testMarginTenHundredths() {
        let pool = [
            candidate(id: "a", name: "A", vector: [1, 0, 0, 0]),
            candidate(id: "b", name: "B", vector: [0, 1, 0, 0]),
        ]
        // cos to A = 0.72, to B = 0.64 — both above the old margin, below the new one.
        let centroid: [Float] = [0.72, 0.64, (1 - 0.72 * 0.72 - 0.64 * 0.64).squareRoot(), 0]
        let result = SpeakerMatcher().match(clusterCentroid: centroid, pool: pool)
        guard case .unmatched(.ambiguousMargin) = result else {
            return XCTFail("expected ambiguousMargin, got \(result)")
        }
    }

    /// A 3-second cluster never decides an identity alone, however close.
    func testShortClusterIsTooShort() {
        let pool = [candidate(id: "gleb-id", name: "Глеб", vector: [1, 0, 0, 0])]
        let result = SpeakerMatcher().matchAllWithAffinity(
            clusterToSegments: ["S1": cluster(seconds: 3, embedding: [1, 0, 0, 0])], pool: pool
        )["S1"]
        guard case .unmatched(.tooShort(let mass, let top, let name)) = result else {
            return XCTFail("expected tooShort, got \(String(describing: result))")
        }
        XCTAssertEqual(mass, 3, accuracy: 1e-9)
        XCTAssertEqual(top, 1, accuracy: 1e-5)
        XCTAssertEqual(name, "Глеб")
    }

    /// Offline path: the splitter votes with the centroid copies first. Its
    /// thresholds must follow the matcher, or `singleMatch` accepts at 0.55.
    func testSplitterFollowsMatcherThresholds() {
        let split = SpeakerMatcher.splitterConfig(for: .default)
        XCTAssertEqual(split.perSegmentAcceptThreshold, 0.70, accuracy: 1e-6)
        XCTAssertEqual(split.perSegmentMarginThreshold, 0.10, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(split.fallbackCentroidAcceptThreshold, 0.70)
    }

    // MARK: - Mic owner (stage2-mic-owner)

    private func centroid(at sim: Float) -> [Float] { [sim, (1 - sim * sim).squareRoot(), 0, 0] }

    private var micPool: [SpeakerMatcher.Candidate] {
        [candidate(id: "me-id", name: "Яков", vector: [1, 0, 0, 0]),
         candidate(id: "alisa-id", name: "Алиса", vector: [0, 0, 1, 0])]
    }

    /// The owner on the built-in mic at 0.69 is still the owner.
    func testMicOwnerAtSixtyNineIsRecognized() {
        let result = SpeakerMatcher(config: .mic(ownerId: "me-id")).matchAllWithAffinity(
            clusterToSegments: ["S1": cluster(seconds: 60, embedding: centroid(at: 0.69))], pool: micPool
        )["S1"]
        guard case .matched(let id, _, _) = result else { return XCTFail("expected owner, got \(String(describing: result))") }
        XCTAssertEqual(id, "me-id")
    }

    /// Anyone else on the mic at 0.65 stays anonymous.
    func testMicForeignAtSixtyFiveStaysAnonymous() {
        let toAlisa: [Float] = [0, (1 - 0.65 * 0.65).squareRoot(), 0.65, 0]
        let result = SpeakerMatcher(config: .mic(ownerId: "me-id")).matchAllWithAffinity(
            clusterToSegments: ["S1": cluster(seconds: 60, embedding: toAlisa)], pool: micPool
        )["S1"]
        guard case .unmatched(.lowSimilarity(_, let name)) = result else {
            return XCTFail("expected lowSimilarity, got \(String(describing: result))")
        }
        XCTAssertEqual(name, "Алиса")
    }

    /// The mass rule spares the owner on the mic, not anyone else.
    func testMicShortClusterOwnerOnly() {
        let matcher = SpeakerMatcher(config: .mic(ownerId: "me-id"))
        let owner = matcher.matchAllWithAffinity(
            clusterToSegments: ["S1": cluster(seconds: 3, embedding: [1, 0, 0, 0])], pool: micPool
        )["S1"]
        guard case .matched(let id, _, _) = owner else { return XCTFail("expected owner, got \(String(describing: owner))") }
        XCTAssertEqual(id, "me-id")
        let guest = matcher.matchAllWithAffinity(
            clusterToSegments: ["S1": cluster(seconds: 3, embedding: [0, 0, 1, 0])], pool: micPool
        )["S1"]
        guard case .unmatched(.tooShort) = guest else { return XCTFail("expected tooShort, got \(String(describing: guest))") }
    }

    // MARK: - Owner-likely clusters

    private func ownerLikely(_ embedding: [Float], seconds: Double = 54, config: SpeakerMatcher.Config) -> Bool {
        let matcher = SpeakerMatcher(config: config)
        let clusters = ["S1": cluster(seconds: seconds, embedding: embedding)]
        let results = matcher.matchAllWithAffinity(clusterToSegments: clusters, pool: micPool)
        return matcher.ownerLikelyClusters(clusterToSegments: clusters, pool: micPool, results: results) == ["S1"]
    }

    /// The live case: 54 s of the owner's own speech at 0.542 under his 0.55.
    /// The threshold holds — no name — but the cluster is not a stranger's.
    func testMicOwnerNearMissStaysUnnamedButOwnerLikely() {
        let matcher = SpeakerMatcher(config: .mic(ownerId: "me-id"))
        let clusters = ["S1": cluster(seconds: 54, embedding: centroid(at: 0.542))]
        let results = matcher.matchAllWithAffinity(clusterToSegments: clusters, pool: micPool)
        guard case .unmatched(.lowSimilarity) = results["S1"] else {
            return XCTFail("the owner threshold must not move, got \(String(describing: results["S1"]))")
        }
        XCTAssertEqual(matcher.ownerLikelyClusters(clusterToSegments: clusters, pool: micPool, results: results), ["S1"])
    }

    /// Too little speech to decide alone is still the owner's best guess.
    func testMicShortNearMissIsOwnerLikely() {
        XCTAssertTrue(ownerLikely(centroid(at: 0.52), seconds: 3, config: .mic(ownerId: "me-id")))
    }

    /// Below the band the owner being "the best candidate" means nothing: with
    /// no profile of their own a stranger's best candidate is often the owner.
    func testMicBelowTheBandIsNotOwnerLikely() {
        XCTAssertFalse(ownerLikely(centroid(at: 0.47), config: .mic(ownerId: "me-id")))
        XCTAssertFalse(ownerLikely(centroid(at: 0.3), config: .mic(ownerId: "me-id")))
    }

    /// Somebody else is the best candidate: a stranger, whatever the owner scores.
    func testMicOtherBestCandidateIsNotOwnerLikely() {
        XCTAssertFalse(ownerLikely([0.5, 0, 0.65, 0.57], config: .mic(ownerId: "me-id")))
    }

    /// A cluster that got the owner's name needs no presumption.
    func testMicMatchedOwnerIsNotListed() {
        XCTAssertFalse(ownerLikely(centroid(at: 0.69), config: .mic(ownerId: "me-id")))
    }

    /// System track and imports have no owner presumption at all.
    func testOwnerLikelyNeedsTheMicConfig() {
        XCTAssertFalse(ownerLikely(centroid(at: 0.542), config: .default))
    }
}
