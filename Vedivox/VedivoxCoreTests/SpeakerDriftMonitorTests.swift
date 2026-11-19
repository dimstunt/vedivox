import XCTest

/// Tests for `SpeakerDriftMonitor`.
///
/// Pure-function tests for `computeAlerts` and integration tests with an
/// in-memory `SpeakerRepository` for the throttling + DB read path.
final class SpeakerDriftMonitorTests: XCTestCase {

    // MARK: - Pure: computeAlerts

    /// Three orthogonal canonicals — no pair should fire.
    func testNoCollisionsForOrthogonalCanonicals() {
        let speakers = [
            (id: "a", name: "Alice", canonical: unit(at: 0, dim: 16)),
            (id: "b", name: "Bob", canonical: unit(at: 1, dim: 16)),
            (id: "c", name: "Carol", canonical: unit(at: 2, dim: 16)),
        ]
        let alerts = SpeakerDriftMonitor.computeAlerts(from: speakers, threshold: 0.6)
        XCTAssertTrue(alerts.isEmpty)
    }

    /// Two near-duplicate canonicals — fire one alert above threshold.
    func testCollisionFiresAlert() {
        let speakers = [
            (id: "a", name: "Alice", canonical: unit(at: 0, dim: 16)),
            (id: "b", name: "Bob-but-poisoned", canonical: unit(at: 0, dim: 16)), // == Alice
            (id: "c", name: "Carol", canonical: unit(at: 5, dim: 16)),
        ]
        let alerts = SpeakerDriftMonitor.computeAlerts(from: speakers, threshold: 0.6)
        XCTAssertEqual(alerts.count, 1)
        let pair = Set([alerts[0].speakerAName, alerts[0].speakerBName])
        XCTAssertEqual(pair, Set(["Alice", "Bob-but-poisoned"]))
        XCTAssertEqual(alerts[0].similarity, 1.0, accuracy: 1e-5)
    }

    /// Multiple collisions are returned sorted worst-first so the log surfaces
    /// the most-suspicious pair at the top. Construction below produces:
    ///   Alice ↔ AliceTwin   sim ≈ 0.999  (above threshold, very close)
    ///   Carol ↔ CarolTwin   sim ≈ 0.707  (above threshold, less close)
    /// All other cross pairs are orthogonal → no false positives.
    func testAlertsSortedBySimilarityDescending() {
        let speakers = [
            (id: "a", name: "Alice", canonical: unit(at: 0, dim: 16)),
            (id: "b", name: "AliceTwin",
             canonical: l2norm([1.0, 0.04] + [Float](repeating: 0, count: 14))),
            (id: "c", name: "Carol", canonical: unit(at: 8, dim: 16)),
            (id: "d", name: "CarolTwin",
             canonical: l2norm([Float](repeating: 0, count: 8) + [1.0, 1.0]
                               + [Float](repeating: 0, count: 6))),
        ]
        let alerts = SpeakerDriftMonitor.computeAlerts(from: speakers, threshold: 0.6)
        XCTAssertEqual(alerts.count, 2,
                       "Expect exactly two pairs above threshold (Alice/AliceTwin and Carol/CarolTwin)")
        XCTAssertGreaterThan(alerts[0].similarity, alerts[1].similarity,
                             "Worst pair must come first")
        let firstPair = Set([alerts[0].speakerAName, alerts[0].speakerBName])
        XCTAssertEqual(firstPair, Set(["Alice", "AliceTwin"]),
                       "Highest-sim pair (Alice/AliceTwin ≈ 0.999) must be first")
    }

    // MARK: - Integration: actor + DB

    /// Set up a poisoned pair in an in-memory DB (Alice and Bob with identical
    /// canonicals), run the monitor, expect exactly one alert.
    func testRunCheckSurfacesPoisonedPairInDB() async throws {
        let db = try makeTestDB()
        let repo = SpeakerRepository(db: db)
        // Explicit v1: the default follows the active diarizer's space.
        let monitor = SpeakerDriftMonitor(
            repo: repo,
            config: .init(driftThreshold: 0.6, minIntervalSeconds: 3600, space: .v1)
        )

        let canon = Speaker.encodeEmbedding(pad(unit(at: 0, dim: 256), to: 256))

        try await repo.save(Speaker(
            id: "alice", nameEn: "Alice", isMe: false, isConfirmed: true, embedding: canon
        ))
        try await repo.save(Speaker(
            id: "bob", nameEn: "Bob-poisoned", isMe: false, isConfirmed: true, embedding: canon
        ))
        try await repo.save(Speaker(
            id: "carol", nameEn: "Carol", isMe: false, isConfirmed: true,
            embedding: Speaker.encodeEmbedding(pad(unit(at: 100, dim: 256), to: 256))
        ))

        let alerts = try await monitor.runCheck()
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].similarity, 1.0, accuracy: 1e-5)
    }

    /// Throttling: if `runCheck` is called twice in quick succession, the second
    /// call returns the cached result without re-querying the DB. Even if the
    /// DB changes between calls, the cached result is what comes back.
    func testThrottlingReturnsCachedResultWithinInterval() async throws {
        let db = try makeTestDB()
        let repo = SpeakerRepository(db: db)
        // Big interval so even a fast test machine stays inside it.
        let monitor = SpeakerDriftMonitor(
            repo: repo,
            config: .init(driftThreshold: 0.6, minIntervalSeconds: 600)
        )

        // Empty DB → no alerts on first run.
        let firstResult = try await monitor.runCheck()
        XCTAssertTrue(firstResult.isEmpty)

        // Add a poisoned pair AFTER first check. Without `force`, second call
        // must still return the empty cached result.
        let canon = Speaker.encodeEmbedding(pad(unit(at: 0, dim: 256), to: 256))
        try await repo.save(Speaker(
            id: "alice", nameEn: "Alice", isMe: false, isConfirmed: true, embedding: canon
        ))
        try await repo.save(Speaker(
            id: "bob", nameEn: "Bob", isMe: false, isConfirmed: true, embedding: canon
        ))

        let cached = try await monitor.runCheck()
        XCTAssertTrue(cached.isEmpty,
                      "Throttle must return cached empty result while DB is freshly poisoned")

        // With `force`, the new DB state is picked up.
        let forced = try await monitor.runCheck(force: true)
        XCTAssertEqual(forced.count, 1)
    }

    /// Монитор дрейфа видит v2: спикеры только со слепком v2 попадают в проверку.
    func testV2OnlySpeakersChecked() async throws {
        let db = try makeTestDB()
        let repo = SpeakerRepository(db: db)
        let canon = Speaker.encodeEmbedding(unit(at: 0, dim: 256))
        for id in ["alice", "bob"] {
            try await repo.save(Speaker(id: id, nameEn: id, isConfirmed: true))
        }
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE speakers SET embeddingV2 = ?", arguments: [canon])
        }
        let monitor = SpeakerDriftMonitor(
            repo: repo,
            config: .init(driftThreshold: 0.75, minIntervalSeconds: 600, space: .v2)
        )
        let alerts = try await monitor.runCheck()
        XCTAssertEqual(alerts.count, 1)
    }

    /// v2: честные двойники на 0.80 не тревожат, почти совпадающие 0.92 — да;
    /// v1 остаётся на 0.6.
    func testV2ThresholdIsHardCap() {
        func pair(_ cos: Float) -> [(id: String, name: String, canonical: [Float])] {
            [(id: "a", name: "A", canonical: unit(at: 0, dim: 16)),
             (id: "b", name: "B", canonical: l2norm([cos, (1 - cos * cos).squareRoot()]
                     + [Float](repeating: 0, count: 14)))]
        }
        let v2 = SpeakerDriftMonitor.Config.forSpace(.v2).driftThreshold
        XCTAssertTrue(SpeakerDriftMonitor.computeAlerts(from: pair(0.80), threshold: v2).isEmpty)
        XCTAssertEqual(SpeakerDriftMonitor.computeAlerts(from: pair(0.92), threshold: v2).count, 1)
        XCTAssertEqual(SpeakerDriftMonitor.Config.forSpace(.v1).driftThreshold, 0.6)
    }

    // MARK: - Test helpers

    private func unit(at index: Int, dim: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[index] = 1.0
        return v
    }

    private func pad(_ v: [Float], to dim: Int) -> [Float] {
        if v.count >= dim { return Array(v.prefix(dim)) }
        return v + [Float](repeating: 0, count: dim - v.count)
    }

    private func l2norm(_ v: [Float]) -> [Float] {
        let mag = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard mag > 0 else { return v }
        return v.map { $0 / mag }
    }
}
