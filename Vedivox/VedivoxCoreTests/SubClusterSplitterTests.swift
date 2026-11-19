import XCTest

/// Pure-logic tests for the per-segment canonical affinity classifier
/// Uses deterministic synthetic embeddings — three orthogonal
/// "speakers" plus blends — so each test asserts a specific behaviour shape
/// without needing real audio.
final class SubClusterSplitterTests: XCTestCase {

    // MARK: - Synthetic vector helpers

    /// Deterministic seeded unit vector. Same seed → same vector.
    private func unitVector(seed: Int) -> [Float] {
        var rng: UInt64 = UInt64(bitPattern: Int64(seed)) &+ 1
        var v = [Float](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            v[i] = Float(rng >> 32) / Float(UInt32.max) - 0.5
        }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / norm }
    }

    /// Convex blend of two unit vectors, normalized.
    private func blend(_ a: [Float], _ b: [Float], lean: Float) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        for i in 0 ..< a.count {
            out[i] = a[i] * (1 - lean) + b[i] * lean
        }
        let norm = sqrt(out.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? out.map { $0 / norm } : out
    }

    private func segment(start: Double, embedding: [Float]) -> DiarizationService.DiarizationSegment {
        DiarizationService.DiarizationSegment(
            start: start,
            end: start + 1.0,
            speaker: "1", // arbitrary cluster id
            embedding: embedding
        )
    }

    private func candidate(id: String, name: String, canonical: [Float], segCount: Int = 100) -> SpeakerMatcher.Candidate {
        SpeakerMatcher.Candidate(
            speakerId: id,
            displayName: name,
            canonical: canonical,
            segmentCount: segCount
        )
    }

    // MARK: - Tests

    /// Pure cluster (every segment exactly matches one canonical) → singleMatch.
    func testPureCluster_singleMatch() {
        let alice = unitVector(seed: 1)
        let bob = unitVector(seed: 2)

        let segments = (0 ..< 20).map { i in segment(start: Double(i), embedding: alice) }
        let pool = [
            candidate(id: "alice", name: "Alice", canonical: alice),
            candidate(id: "bob", name: "Bob", canonical: bob),
        ]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        guard case .singleMatch(let id, let name, let conf) = result else {
            XCTFail("Expected singleMatch, got \(result)")
            return
        }
        XCTAssertEqual(id, "alice")
        XCTAssertEqual(name, "Alice")
        XCTAssertGreaterThan(conf, 0.95, "Pure cluster should have very high confidence")
    }

    /// Two distinct sub-groups (10 Alice + 10 Bob) → split into two SubGroups.
    func testTwoWaySplit_emitsTwoSubGroups() {
        let alice = unitVector(seed: 1)
        let bob = unitVector(seed: 2)

        var segments: [DiarizationService.DiarizationSegment] = []
        for i in 0 ..< 10 {
            segments.append(segment(start: Double(i), embedding: alice))
        }
        for i in 0 ..< 10 {
            segments.append(segment(start: Double(100 + i), embedding: bob))
        }

        let pool = [
            candidate(id: "alice", name: "Alice", canonical: alice),
            candidate(id: "bob", name: "Bob", canonical: bob),
        ]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        guard case .splitMatches(let groups) = result else {
            XCTFail("Expected splitMatches, got \(result)")
            return
        }

        let byId = Dictionary(uniqueKeysWithValues: groups.compactMap { g -> (String, SubClusterSplitter.SubGroup)? in
            guard let id = g.speakerId else { return nil }
            return (id, g)
        })
        XCTAssertEqual(byId["alice"]?.segmentKeys.count, 10)
        XCTAssertEqual(byId["bob"]?.segmentKeys.count, 10)
        XCTAssertNil(groups.first(where: { $0.speakerId == nil }), "No unassigned tail expected")
    }

    /// Three distinct sub-groups (M7-style: Ирмы + Клара + Роза all in
    /// one over-merged cluster) → all three emitted.
    func testThreeWaySplit_emitsThreeSubGroups() {
        let irma = unitVector(seed: 10)
        let clara = unitVector(seed: 11)
        let rosa = unitVector(seed: 12)

        var segments: [DiarizationService.DiarizationSegment] = []
        for i in 0 ..< 30 { segments.append(segment(start: Double(i), embedding: irma)) }
        for i in 0 ..< 15 { segments.append(segment(start: Double(100 + i), embedding: clara)) }
        for i in 0 ..< 10 { segments.append(segment(start: Double(200 + i), embedding: rosa)) }

        let pool = [
            candidate(id: "z", name: "Ирмы", canonical: irma),
            candidate(id: "a", name: "Клара", canonical: clara),
            candidate(id: "v", name: "Роза", canonical: rosa),
        ]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        guard case .splitMatches(let groups) = result else {
            XCTFail("Expected splitMatches, got \(result)")
            return
        }
        let nonNil = groups.filter { $0.speakerId != nil }
        XCTAssertEqual(nonNil.count, 3, "Three significant sub-groups expected")
    }

    /// Single dominant + tiny unknown tail (18 Alice + 2 random) → whole
    /// cluster labelled Alice (dominant fast path).
    func testDominantPlusTinyTail_singleMatch() {
        let alice = unitVector(seed: 1)
        let outsider = unitVector(seed: 999)

        var segments: [DiarizationService.DiarizationSegment] = []
        for i in 0 ..< 18 { segments.append(segment(start: Double(i), embedding: alice)) }
        for i in 0 ..< 2 { segments.append(segment(start: Double(100 + i), embedding: outsider)) }

        let pool = [candidate(id: "alice", name: "Alice", canonical: alice)]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        guard case .singleMatch(let id, _, _) = result else {
            XCTFail("Expected singleMatch (dominant fast path), got \(result)")
            return
        }
        XCTAssertEqual(id, "alice")
    }

    /// All segments below acceptThreshold to every canonical → fallBack
    /// (caller should run cluster-centroid match).
    func testAllUnassigned_fallBack() {
        // Pool: just one canonical pointing seed-100 way.
        let known = unitVector(seed: 100)
        // Cluster: all segments orthogonal-ish to it.
        let outsider = unitVector(seed: 999)

        let segments = (0 ..< 10).map { i in segment(start: Double(i), embedding: outsider) }
        let pool = [candidate(id: "k", name: "Known", canonical: known)]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        if case .fallBack = result {
            // ok
        } else {
            XCTFail("Expected fallBack for all-unassigned cluster, got \(result)")
        }
    }

    /// Empty pool → fallBack regardless of segments.
    func testEmptyPool_fallBack() {
        let alice = unitVector(seed: 1)
        let segments = (0 ..< 10).map { i in segment(start: Double(i), embedding: alice) }

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: [])
        if case .fallBack = result {
            // ok
        } else {
            XCTFail("Expected fallBack for empty pool")
        }
    }

    /// Sub-group below `minSegmentsPerSubGroup` is demoted into the unknown
    /// tail rather than emitted as its own group. Significant + small =
    /// significant alone (since fraction would still pass dominant), or split
    /// with a tail.
    func testTinySubGroupDemoted() {
        let alice = unitVector(seed: 1)
        let bob = unitVector(seed: 2)

        var segments: [DiarizationService.DiarizationSegment] = []
        for i in 0 ..< 15 { segments.append(segment(start: Double(i), embedding: alice)) }
        for i in 0 ..< 3 { segments.append(segment(start: Double(100 + i), embedding: bob)) }

        let pool = [
            candidate(id: "alice", name: "Alice", canonical: alice),
            candidate(id: "bob", name: "Bob", canonical: bob),
        ]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        // Bob has only 3 votes (< 5) → demoted. Alice has 15/18 = 0.83 fraction
        // (≥ dominantFraction 0.8) → singleMatch Alice.
        guard case .singleMatch(let id, _, _) = result else {
            XCTFail("Expected singleMatch (Bob demoted, Alice dominant), got \(result)")
            return
        }
        XCTAssertEqual(id, "alice")
    }

    // MARK: - Centroid fallback (post-split rescue, follow-up)

    /// M7 case: cluster contains a clear sub-group of Felix's voice but
    /// individual per-segment sims sit just below `perSegmentAcceptThreshold`
    /// because the segments are short and noisy. Initial split produces an
    /// UNKNOWN tail; the centroid-fallback rescue should promote it to Felix
    /// when the aggregate centroid clears the stricter threshold.
    func testCentroidFallback_rescuesNoisyButCoherentSubGroup() {
        let alice = unitVector(seed: 1)
        let felix = unitVector(seed: 2)

        var segments: [DiarizationService.DiarizationSegment] = []
        // Significant Alice sub-group — clean.
        for i in 0 ..< 10 {
            segments.append(segment(start: Double(i), embedding: alice))
        }
        // Felix sub-group — each segment has Felix 70% + noise 30%, low individual
        // margin but centroid is clearly Felix.
        for i in 0 ..< 10 {
            let noise = unitVector(seed: 500 + i)
            let noisy = blend(felix, noise, lean: 0.3)
            segments.append(segment(start: Double(100 + i), embedding: noisy))
        }

        let pool = [
            candidate(id: "alice", name: "Alice", canonical: alice),
            candidate(id: "felix", name: "Felix", canonical: felix),
        ]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        guard case .splitMatches(let groups) = result else {
            XCTFail("Expected splitMatches, got \(result)")
            return
        }

        // The Felix-noisy group might be split per-segment, OR rescued via
        // centroid fallback. Either way, no UNKNOWN sub-group should remain
        // when its centroid would clearly match Felix.
        let unknownGroup = groups.first(where: { $0.speakerId == nil })
        XCTAssertNil(unknownGroup, "Centroid fallback should rescue Felix-leaning UNKNOWN tail")

        let felixGroup = groups.first(where: { $0.speakerId == "felix" })
        XCTAssertNotNil(felixGroup, "Felix should be a labelled sub-group")
        XCTAssertGreaterThanOrEqual(felixGroup?.segmentKeys.count ?? 0, 5)
    }

    /// 50/50 mix of Alice + Bob whose mean lands near a third canonical
    /// "Charlie" — purity check must reject the rescue, leaving the group
    /// as UNKNOWN. We construct Charlie to sit on the midpoint of A and B
    /// so the centroid sim to Charlie is high but no single segment is near
    /// Charlie.
    func testCentroidFallback_rejectsMixViaPurityCheck() {
        let alice = unitVector(seed: 1)
        let bob = unitVector(seed: 2)
        // Charlie ≈ midpoint(Alice, Bob) — pretends to match the centroid
        // but no individual segment is actually close to him.
        let charlie = blend(alice, bob, lean: 0.5)

        var segments: [DiarizationService.DiarizationSegment] = []
        // Only the unassigned tail — none of A/B votes pass per-seg margin
        // because Alice and Bob are equally close to each segment's noisy
        // embedding. Tail is meant to land in centroid fallback.
        for i in 0 ..< 10 {
            segments.append(segment(start: Double(i), embedding: alice))
        }
        for i in 0 ..< 10 {
            segments.append(segment(start: Double(100 + i), embedding: bob))
        }

        let pool = [
            candidate(id: "alice", name: "Alice", canonical: alice),
            candidate(id: "bob", name: "Bob", canonical: bob),
            candidate(id: "charlie", name: "Charlie", canonical: charlie),
        ]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        // The cluster splits between Alice and Bob (per-seg path). Charlie must
        // not steal anything — both purity (most segs sim < 0.5 to Charlie since
        // Charlie is just an avg of A and B) and per-seg margin protect it.
        // Either splitMatches with no Charlie or fallBack — both acceptable;
        // Charlie taking the whole cluster is the failure this guards.
        switch result {
        case .splitMatches(let groups):
            XCTAssertNil(groups.first(where: { $0.speakerId == "charlie" }), "Charlie must not capture an A/B mix via fallback")
        case .singleMatch(let speakerId, _, _):
            XCTAssertNotEqual(speakerId, "charlie", "Charlie must not capture an A/B mix via fallback")
        case .fallBack:
            break
        }
    }

    /// UNKNOWN tail with too few segments (< minSegmentsForCentroidFallback)
    /// must NOT trigger the rescue, even if the small group's centroid would
    /// match. Below the floor the centroid is too noisy to trust.
    func testCentroidFallback_skippedWhenTailTooSmall() {
        let alice = unitVector(seed: 1)
        let felix = unitVector(seed: 2)

        var segments: [DiarizationService.DiarizationSegment] = []
        for i in 0 ..< 20 {
            segments.append(segment(start: Double(i), embedding: alice))
        }
        // Only 3 noisy Felix-leaning segments — below the floor.
        for i in 0 ..< 3 {
            let noise = unitVector(seed: 500 + i)
            let noisy = blend(felix, noise, lean: 0.3)
            segments.append(segment(start: Double(100 + i), embedding: noisy))
        }

        let pool = [
            candidate(id: "alice", name: "Alice", canonical: alice),
            candidate(id: "felix", name: "Felix", canonical: felix),
        ]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        // 20 Alice / 3 unknown — Alice fraction 0.87 → singleMatch fast path
        // (no UNKNOWN sub-group emitted at all in this case).
        if case .singleMatch(let id, _, _) = result {
            XCTAssertEqual(id, "alice")
        } else {
            XCTFail("Expected singleMatch when Alice dominates and Felix-tail is below fallback floor; got \(result)")
        }
    }

    /// Candidate with too-few DB segments is filtered out of the pool — even
    /// if the cluster perfectly matches it, splitter should not vote for it.
    func testLowDataCanonicalFiltered() {
        let alice = unitVector(seed: 1)

        let segments = (0 ..< 10).map { i in segment(start: Double(i), embedding: alice) }
        let pool = [
            // Alice only has 2 segments in DB — below minSegmentsForCanonical (5)
            candidate(id: "alice", name: "Alice", canonical: alice, segCount: 2),
        ]

        let result = SubClusterSplitter().resolve(clusterSegments: segments, pool: pool)
        if case .fallBack = result {
            // ok — pool filtered out the only candidate
        } else {
            XCTFail("Expected fallBack when pool is empty after filter, got \(result)")
        }
    }
}
