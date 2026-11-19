import XCTest

/// Tests for the robust `SpeakerRepository.recalculateEmbedding`:
/// self-cleaning purified centroid + identity-space invariant rejection.
///
/// Pure-function tests for `purifiedCentroid` use synthetic embeddings; the
/// integration check (with actual DB rejection) uses an in-memory database from
/// `makeTestDB()`.
final class RecalculateEmbeddingTests: XCTestCase {

    // MARK: - Pure: purifiedCentroid

    /// 9 segments clustered around one direction + 1 obvious outlier. Purified
    /// centroid keeps top-50% (~5 of 10) and is therefore close to the bulk.
    func testPurifiedCentroidIgnoresOutlier() {
        let dim = 16
        var bulk = [[Float]]()
        for _ in 0 ..< 9 {
            var v = [Float](repeating: 0, count: dim)
            v[0] = 1.0 + Float.random(in: -0.05 ... 0.05)
            v[1] = Float.random(in: -0.05 ... 0.05)
            bulk.append(v)
        }
        // Outlier in a totally different direction
        var outlier = [Float](repeating: 0, count: dim)
        outlier[5] = 1.0
        bulk.append(outlier)

        let purified = SpeakerRepository.purifiedCentroid(embeddings: bulk)
        XCTAssertNotNil(purified)
        // First component should dominate (true mean direction).
        XCTAssertGreaterThan(purified![0], 0.9,
                             "purified[0] should be close to 1.0 (true mean), got \(purified![0])")
        XCTAssertLessThan(abs(purified![5]), 0.2,
                          "outlier direction should be largely rejected, got \(purified![5])")
    }

    /// When too few segments survive the floor, returns nil — caller keeps the old
    /// canonical untouched.
    func testPurifiedCentroidReturnsNilBelowMinSegments() {
        let dim = 16
        let inputs = (0 ..< 3).map { _ in [Float](repeating: 1, count: dim) }
        let cfg = SpeakerRepository.RecalcConfig(
            keepFraction: 0.1, minSegmentsAfterFilter: 5,
            identityInvariantThresholds: [.v1: 0.6, .v2: 0.75]
        )
        let result = SpeakerRepository.purifiedCentroid(embeddings: inputs, config: cfg)
        XCTAssertNil(result, "Below floor → nil so caller keeps old canonical")
    }

    /// Empty input returns nil safely — defensive programming for the bootstrap case.
    func testPurifiedCentroidReturnsNilForEmpty() {
        XCTAssertNil(SpeakerRepository.purifiedCentroid(embeddings: []))
    }

    /// Result is always L2-normalized so downstream cosine math is stable.
    func testPurifiedCentroidIsUnitNorm() {
        let dim = 16
        let inputs = (0 ..< 10).map { _ -> [Float] in
            var v = [Float](repeating: 0, count: dim)
            v[0] = Float.random(in: 0.5 ... 1.5)
            v[1] = Float.random(in: -0.2 ... 0.2)
            return v
        }
        let result = SpeakerRepository.purifiedCentroid(embeddings: inputs)!
        let mag = result.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(mag, 1.0, accuracy: 1e-5)
    }

    // MARK: - Integration: identity-space invariant

    /// Set up two confirmed speakers with near-identical canonicals in an in-memory
    /// DB, then attempt to recalculate one. The recalculation will produce a canonical
    /// that — by construction — collides with the other confirmed speaker. The
    /// invariant must reject the update and leave the original canonical intact.
    func testIdentityInvariantBlocksUpdateOnCollision() async throws {
        let db = try makeTestDB()
        let repo = SpeakerRepository(db: db)

        let dim = 256
        var canonA = [Float](repeating: 0, count: dim)
        canonA[0] = 1.0 // unit vector along axis 0
        let canonAData = Speaker.encodeEmbedding(canonA)

        // Speaker A: confirmed, with canonical pointing at axis 0.
        let alice = Speaker(
            id: "alice-id", nameEn: "Alice", isMe: false, isConfirmed: true,
            embedding: canonAData
        )
        try await repo.save(alice)

        // Speaker B: confirmed, with a *different* canonical for the moment.
        var canonB = [Float](repeating: 0, count: dim)
        canonB[1] = 1.0
        let bob = Speaker(
            id: "bob-id", nameEn: "Bob", isMe: false, isConfirmed: true,
            embedding: Speaker.encodeEmbedding(canonB)
        )
        try await repo.save(bob)

        // Now seed B's transcript_segments with embeddings that all point at axis 0
        // (i.e. identical to A's canonical) — this simulates contamination.
        let meeting = makeMeeting(id: "test-meeting")
        let meetingRepo = MeetingRepository(db: db)
        try await meetingRepo.save(meeting)

        var segments: [TranscriptSegment] = []
        for i in 0 ..< 10 {
            var seg = makeSegment(
                meetingId: meeting.id,
                speakerId: bob.id,
                speakerLabel: "Bob",
                source: .system,
                startTime: Double(i),
                endTime: Double(i) + 1
            )
            seg.embedding = canonAData
            segments.append(seg)
        }
        try await meetingRepo.saveSegments(segments)

        // Sanity check: B's canonical right now is along axis 1 (the original).
        let beforeBob = try await repo.find(bob.id)!
        let beforeCanon = beforeBob.embeddingArray!
        XCTAssertGreaterThan(beforeCanon[1], 0.9, "Bob's canonical should start on axis 1")

        // Trigger recalculation. Bob's segments are all identical to Alice's
        // canonical → recomputed canonical for Bob would equal Alice's. Identity
        // invariant must reject and keep Bob's old canonical.
        try await repo.recalculateEmbedding(speakerId: bob.id)

        let afterBob = try await repo.find(bob.id)!
        let afterCanon = afterBob.embeddingArray!
        XCTAssertGreaterThan(afterCanon[1], 0.9,
                             "Identity invariant must reject the update — Bob's canonical should still be on axis 1")
        XCTAssertLessThan(afterCanon[0], 0.1,
                          "Bob's canonical must NOT have shifted to Alice's direction")
    }

    /// Sanity: a normal recalculation that doesn't collide with any other confirmed
    /// speaker is allowed through. Without this, the invariant could trivially break
    /// every recalculation in tests.
    func testNormalRecalculationStillUpdates() async throws {
        let db = try makeTestDB()
        let repo = SpeakerRepository(db: db)

        // One speaker, no neighbors to collide with.
        let dim = 256
        var initialCanon = [Float](repeating: 0, count: dim)
        initialCanon[0] = 1.0
        let alice = Speaker(
            id: "alice-id", nameEn: "Alice", isMe: false, isConfirmed: true,
            embedding: Speaker.encodeEmbedding(initialCanon)
        )
        try await repo.save(alice)

        let meeting = makeMeeting(id: "test-meeting")
        let meetingRepo = MeetingRepository(db: db)
        try await meetingRepo.save(meeting)

        // Seed segments with embeddings on axis 1 — totally different from initial.
        var newDirection = [Float](repeating: 0, count: dim)
        newDirection[1] = 1.0
        var segments: [TranscriptSegment] = []
        for i in 0 ..< 10 {
            var seg = makeSegment(
                meetingId: meeting.id,
                speakerId: alice.id, speakerLabel: "Alice",
                source: .system, startTime: Double(i), endTime: Double(i) + 1
            )
            seg.embedding = Speaker.encodeEmbedding(newDirection)
            segments.append(seg)
        }
        try await meetingRepo.saveSegments(segments)

        try await repo.recalculateEmbedding(speakerId: alice.id)

        let after = try await repo.find(alice.id)!
        let canon = after.embeddingArray!
        XCTAssertGreaterThan(canon[1], 0.9,
                             "With no other confirmed speakers, recalc should freely move Alice's canonical")
    }

    // MARK: - Invariant per space and recalc outcome (guard-rescue-and-v2-canon)

    /// Unit vector at cosine `cos` to axis 0.
    private func atCos(_ cos: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[0] = cos
        v[1] = (1 - cos * cos).squareRoot()
        return v
    }

    /// Confirmed "Other" with canonical on axis 0 and confirmed "Self" whose
    /// only meeting voice sits at `cos` to it, both in `space`. Self's own
    /// canonical in that space is on axis 2, or NULL when `selfCanonical` is false.
    private func collisionFixture(
        space: EmbeddingSpace, cos: Float, selfCanonical: Bool = true
    ) async throws -> (SpeakerRepository, DatabaseManager) {
        let db = try makeTestDB()
        let repo = SpeakerRepository(db: db)
        let meetingRepo = MeetingRepository(db: db)
        var axis2 = [Float](repeating: 0, count: 256)
        axis2[2] = 1
        let otherBlob = Speaker.encodeEmbedding(atCos(1))
        let selfBlob = selfCanonical ? Speaker.encodeEmbedding(axis2) : nil
        try await repo.save(Speaker(id: "other", nameEn: "Other", isConfirmed: true))
        try await repo.save(Speaker(id: "self", nameEn: "Self", isConfirmed: true))
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE speakers SET \(space.rawValue) = ? WHERE id = 'other'",
                           arguments: [otherBlob])
            try db.execute(sql: "UPDATE speakers SET \(space.rawValue) = ? WHERE id = 'self'",
                           arguments: [selfBlob])
        }
        var meeting = makeMeeting()
        if space == .v2 { meeting.diarizer = "offline" }
        try await meetingRepo.save(meeting)
        try await meetingRepo.saveSegments((0 ..< 10).map { i in
            var seg = makeSegment(meetingId: meeting.id, speakerId: "self", speakerLabel: "Self",
                                  source: .system, startTime: Double(i) * 2, endTime: Double(i) * 2 + 2)
            seg.embedding = Speaker.encodeEmbedding(atCos(cos))
            return seg
        })
        return (repo, db)
    }

    private func storedCanonical(_ db: DatabaseManager, _ space: EmbeddingSpace) async throws -> [Float]? {
        try await db.reader.read { db in
            try Data.fetchOne(db, sql: "SELECT \(space.rawValue) FROM speakers WHERE id = 'self'")
        }.map { Speaker.decodeEmbedding($0) }
    }

    /// Честный двойник в v2 (0.70) проходит — порог v2 0.75.
    func testV2HonestTwinSaved() async throws {
        let (repo, db) = try await collisionFixture(space: .v2, cos: 0.70)
        let outcome = try await repo.recalculateEmbedding(speakerId: "self", space: .v2)
        XCTAssertEqual(outcome, .saved)
        let stored = try await storedCanonical(db, .v2)
        XCTAssertEqual(stored?[0] ?? 0, 0.70, accuracy: 0.01)
    }

    /// Сосед без голосов в пространстве сравнивается по колонке; у спикера с
    /// одной встречей действует прежний порог 0.75.
    func testV2FewVoicesRejectedAgainstNeighborColumn() async throws {
        let (repo, db) = try await collisionFixture(space: .v2, cos: 0.78)
        let outcome = try await repo.recalculateEmbedding(speakerId: "self", space: .v2)
        guard case .rejected(let with, let sim) = outcome else {
            return XCTFail("expected rejected, got \(outcome)")
        }
        XCTAssertEqual(with, "Other")
        XCTAssertEqual(sim, 0.78, accuracy: 0.01)
        let stored = try await storedCanonical(db, .v2)
        XCTAssertEqual(stored?[2], 1, "old canonical kept")
    }

    // MARK: - Invariant by separability (separability-invariant)

    /// Unit vector in the plane of axes 0 and 1, at this angle to axis 0.
    private func atAngle(_ radians: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[0] = Foundation.cos(radians)
        v[1] = Foundation.sin(radians)
        return v
    }

    /// Outlier filter off: the tests decide which voices enter the canonical.
    private var keepAll: SpeakerRepository.RecalcConfig {
        var config = SpeakerRepository.RecalcConfig.default
        config.keepFraction = 1
        return config
    }

    /// Confirmed speaker with an optional stored v2 canonical and one offline
    /// meeting per voice. Meeting ids are "<id>-m<index>".
    private func seedV2Speaker(
        _ db: DatabaseManager, id: String, column: [Float]?,
        voices: [(embedding: [Float], seconds: Double)]
    ) async throws {
        try await SpeakerRepository(db: db).save(Speaker(id: id, nameEn: id, isConfirmed: true))
        let blob = column.map { Speaker.encodeEmbedding($0) }
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE speakers SET embeddingV2 = ? WHERE id = ?", arguments: [blob, id])
        }
        let meetingRepo = MeetingRepository(db: db)
        for (index, voice) in voices.enumerated() {
            var meeting = makeMeeting(id: "\(id)-m\(index)")
            meeting.diarizer = "offline"
            try await meetingRepo.save(meeting)
            var segment = makeSegment(meetingId: meeting.id, speakerId: id, speakerLabel: id,
                                      source: .system, startTime: 0, endTime: voice.seconds)
            segment.embedding = Speaker.encodeEmbedding(voice.embedding)
            try await meetingRepo.saveSegments([segment])
        }
    }

    private func v2Canonical(_ db: DatabaseManager, _ id: String) async throws -> [Float]? {
        try await db.reader.read { db in
            try Data.fetchOne(db, sql: "SELECT embeddingV2 FROM speakers WHERE id = ?", arguments: [id])
        }.map { Speaker.decodeEmbedding($0) }
    }

    private var axis2: [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[2] = 1
        return v
    }

    private func lookalikes(_ count: Int) -> [(embedding: [Float], seconds: Double)] {
        (0 ..< count).map {
            (lookalikeVoice(index: $0, s: 0.485, canonSim: 0.78, count: 9, dim: 256), 60)
        }
    }

    /// Честный двойник: слепок на 0.78 к соседу — выше прежнего порога 0.75, —
    /// но каждый голос встречи заметно ближе к своему слепку. Сохраняется.
    func testV2HonestTwinWithSeparableVoicesSaved() async throws {
        let db = try makeTestDB()
        try await seedV2Speaker(db, id: "Other", column: atAngle(0), voices: [])
        try await seedV2Speaker(db, id: "self", column: axis2, voices: lookalikes(9))
        let outcome = try await SpeakerRepository(db: db)
            .recalculateEmbedding(speakerId: "self", space: .v2, config: keepAll)
        XCTAssertEqual(outcome, .saved)
        let stored = try await v2Canonical(db, "self")
        XCTAssertEqual(cosineSimilarity(stored ?? axis2, atAngle(0)), 0.78, accuracy: 0.005)
    }

    /// Отравленные встречи: голоса двух встреч из девяти ближе к соседу, чем к
    /// своему слепку без них. Отказ называет соседа и обе встречи, прежний
    /// слепок на месте.
    func testV2CollisionRejectedWhenCanonicalExists() async throws {
        let db = try makeTestDB()
        var voices = lookalikes(7)
        for (index, seconds) in [(100, 100.0), (101, 80.0)] {
            var poisoned = [Float](repeating: 0, count: 256)
            poisoned[0] = 0.9
            poisoned[index] = Float(0.19).squareRoot()
            voices.append((poisoned, seconds))
        }
        try await seedV2Speaker(db, id: "Other", column: atAngle(0), voices: [])
        try await seedV2Speaker(db, id: "self", column: axis2, voices: voices)
        let outcome = try await SpeakerRepository(db: db)
            .recalculateEmbedding(speakerId: "self", space: .v2, config: keepAll)
        guard case .inseparable(let from, let share, let meetings) = outcome else {
            return XCTFail("expected inseparable, got \(outcome)")
        }
        XCTAssertEqual(from, "Other")
        XCTAssertEqual(share, 0.30, accuracy: 0.001)
        XCTAssertEqual(meetings, ["self-m7", "self-m8"])
        let stored = try await v2Canonical(db, "self")
        XCTAssertEqual(stored?[2], 1, "old canonical kept")
    }

    /// Колонка соседа застыла на 0.82 к новому слепку, а его живой слепок — на
    /// 0.74: решает живой, пересчёт сохраняется.
    func testV2LiveNeighborCanonicalDecidesNotStaleColumn() async throws {
        let db = try makeTestDB()
        try await seedV2Speaker(db, id: "Other", column: atAngle(acos(0.82)),
                                voices: [(atAngle(acos(0.74)), 60)])
        try await seedV2Speaker(db, id: "self", column: axis2, voices: [(atAngle(0), 60)])
        let outcome = try await SpeakerRepository(db: db).recalculateEmbedding(speakerId: "self", space: .v2)
        XCTAssertEqual(outcome, .saved)
    }

    /// Взаимная блокировка: сохранённые слепки двух спикеров на 0.82 к новому
    /// слепку другого (прежнее правило отклоняло обоих), живые — на 0.74, у
    /// каждого три различимых голоса. Оба пересчёта сохраняются в любом порядке.
    func testStaleCanonicalsDoNotLockEachOther() async throws {
        let apart = acos(Float(0.74)), stale = acos(Float(0.82))
        for order in [["p", "q"], ["q", "p"]] {
            let db = try makeTestDB()
            try await seedV2Speaker(db, id: "p", column: atAngle(apart - stale),
                                    voices: (0 ..< 3).map { _ in (atAngle(0), 60) })
            try await seedV2Speaker(db, id: "q", column: atAngle(stale),
                                    voices: (0 ..< 3).map { _ in (atAngle(apart), 60) })
            let repo = SpeakerRepository(db: db)
            for id in order {
                let outcome = try await repo.recalculateEmbedding(speakerId: id, space: .v2)
                XCTAssertEqual(outcome, .saved, "\(id) in order \(order)")
            }
            let p = try await v2Canonical(db, "p"), q = try await v2Canonical(db, "q")
            XCTAssertEqual(cosineSimilarity(p ?? axis2, q ?? axis2), 0.74, accuracy: 0.005)
        }
    }

    /// Текст отказа для команд: сосед, доля речи, не больше пяти встреч.
    func testInseparableDescription() {
        let two = SpeakerRepository.RecalcOutcome.inseparable(
            from: "X", share: 0.14,
            meetings: ["AAAA1111-0000-0000-0000-000000000000", "BBBB2222-0000-0000-0000-000000000000"]
        )
        XCTAssertEqual(
            two.description,
            "rejected: 2 voice(s) (14% of speech) closer to 'X' — meetings AAAA1111, BBBB2222; old kept"
        )
        let many = SpeakerRepository.RecalcOutcome.inseparable(
            from: "X", share: 0.5, meetings: (1 ... 7).map { "m\($0)" }
        )
        XCTAssertTrue(many.description.contains("meetings m1, m2, m3, m4, m5 +2 more;"), many.description)
        let none = SpeakerRepository.RecalcOutcome.inseparable(from: "X", share: 0, meetings: [])
        XCTAssertEqual(none.description, "rejected: voices barely closer to own canonical than to 'X'; old kept")
    }

    /// v1 keeps its 0.6 threshold.
    func testV1ThresholdUnchanged() async throws {
        let (repo, _) = try await collisionFixture(space: .v1, cos: 0.65)
        let outcome = try await repo.recalculateEmbedding(speakerId: "self", space: .v1)
        guard case .rejected = outcome else { return XCTFail("expected rejected, got \(outcome)") }
    }

    /// Новый спикер без слепка рядом с загрязнённым всё равно получает слепок.
    func testEmptyCanonicalSavedDespiteCollision() async throws {
        let (repo, db) = try await collisionFixture(space: .v2, cos: 0.78, selfCanonical: false)
        let outcome = try await repo.recalculateEmbedding(speakerId: "self", space: .v2)
        guard case .savedDespiteCollision(let with, _) = outcome else {
            return XCTFail("expected savedDespiteCollision, got \(outcome)")
        }
        XCTAssertEqual(with, "Other")
        let stored = try await storedCanonical(db, .v2)
        XCTAssertEqual(stored?[0] ?? 0, 0.78, accuracy: 0.01)
    }

    /// Automatic paths (pipeline, enrollment) nobody vouched for keep rejecting.
    func testAutomaticRecalcKeepsEmptyCanonicalOnCollision() async throws {
        let (repo, db) = try await collisionFixture(space: .v2, cos: 0.78, selfCanonical: false)
        let outcome = try await repo.recalculateEmbedding(speakerId: "self", space: .v2, config: .automatic)
        guard case .rejected = outcome else { return XCTFail("expected rejected, got \(outcome)") }
        let stored = try await storedCanonical(db, .v2)
        XCTAssertNil(stored)
    }

    func testNoVoicesSkipped() async throws {
        let (repo, _) = try await collisionFixture(space: .v2, cos: 0.5)
        let outcomes = try await repo.recalculateEmbedding(speakerId: "self")
        XCTAssertEqual(outcomes[.v1], .skipped, "self has no v1 meetings")
        XCTAssertEqual(outcomes[.v2], .saved)
    }

    // MARK: - Meeting voices (speaker-row-per-mint, design § решение 4)

    private func voice(_ id: String, day: Double, emb: [Float], sec: Double) -> SpeakerRepository.MeetingVoice {
        SpeakerRepository.MeetingVoice(
            meetingId: id,
            meetingStart: Date(timeIntervalSince1970: day * 86400),
            embedding: emb,
            speechSeconds: sec
        )
    }

    private func axis(_ i: Int, dim: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[i] = 1
        return v
    }

    /// 5.1: 300 реплик-копий центроида → один голос встречи, равный вектору,
    /// с массой в секундах речи.
    func testPerMeetingVoicesDedupesCentroidCopies() async throws {
        let db = try makeTestDB()
        let repo = SpeakerRepository(db: db)
        let meetingRepo = MeetingRepository(db: db)
        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        let speaker = makeSpeaker(name: "Савва")
        try await repo.save(speaker)

        var centroid = [Float](repeating: 0, count: 256)
        centroid[0] = 1
        let blob = Speaker.encodeEmbedding(centroid)
        var segments: [TranscriptSegment] = []
        for i in 0 ..< 300 {
            var seg = makeSegment(meetingId: meeting.id, speakerId: speaker.id,
                                  speakerLabel: "Савва", source: .system,
                                  startTime: Double(i), endTime: Double(i) + 1)
            seg.embedding = blob
            segments.append(seg)
        }
        try await meetingRepo.saveSegments(segments)

        let voices = try await repo.perMeetingVoices(speakerId: speaker.id, space: .v1)
        XCTAssertEqual(voices.count, 1)
        XCTAssertEqual(voices[0].speechSeconds, 300, accuracy: 0.01)
        XCTAssertEqual(voices[0].embedding[0], 1.0, accuracy: 1e-5,
                       "300 копий → один голос, равный вектору")
    }

    /// 5.3: вес насыщается — 3000 с речи не дают больше голосов, чем 60 с.
    func testWeightSaturatesAtCap() {
        let voices = [
            voice("talkative", day: 0, emb: axis(0), sec: 3000),
            voice("short", day: 1, emb: axis(1), sec: 60),
        ]
        let canon = SpeakerRepository.canonicalFromVoices(voices)!
        XCTAssertEqual(canon[0], canon[1], accuracy: 1e-5,
                       "оба веса упёрлись в потолок — встречи равноправны")
    }

    /// 5.3: болтливая давняя встреча против пяти свежих — слепок отражает
    /// свежие, а не одну болтливую.
    func testTalkativeMeetingDoesNotOutvoteFreshOnes() {
        var voices = [voice("old", day: 0, emb: axis(0), sec: 3000)]
        for i in 1 ... 5 {
            voices.append(voice("f\(i)", day: Double(i), emb: axis(1), sec: 60))
        }
        let canon = SpeakerRepository.canonicalFromVoices(voices)!
        XCTAssertGreaterThan(canon[1], 0.9, "пять свежих встреч задают направление")
        XCTAssertLessThan(canon[0], 0.3, "болтливая не рулит слепком")
    }

    /// 5.4: встреча с парой секунд чужого голоса не входит (ниже пола).
    func testScrapMeetingBelowFloorExcluded() {
        let voices = [
            voice("m1", day: 1, emb: axis(0), sec: 120),
            voice("m2", day: 2, emb: axis(0), sec: 90),
            voice("scrap", day: 3, emb: axis(2), sec: 5),
        ]
        let canon = SpeakerRepository.canonicalFromVoices(voices)!
        XCTAssertLessThan(abs(canon[2]), 1e-6, "обрывок не вошёл в слепок")
    }

    /// 5.4: встреча-выброс с достаточной массой (чужая разметка) отбрасывается
    /// очисткой целиком.
    func testOutlierMeetingWithMassDroppedWhole() {
        var voices = (1 ... 5).map { voice("m\($0)", day: Double($0), emb: axis(0), sec: 120) }
        voices.append(voice("bad", day: 6, emb: axis(2), sec: 300))
        let canon = SpeakerRepository.canonicalFromVoices(voices)!
        XCTAssertLessThan(abs(canon[2]), 0.05, "встреча-выброс отброшена целиком")
    }

    /// Девять обрывков по 13–40 с не объявляют выбросом встречу на час речи:
    /// при отсеве голосуют только встречи с достаточной массой.
    func testScrapsDoNotOutvoteLongMeeting() {
        var voices = [voice("long", day: 0, emb: axis(0), sec: 3791)]
        for i in 1 ... 9 { voices.append(voice("scrap\(i)", day: Double(i), emb: axis(1), sec: 10 + Double(i) * 3)) }
        let selection = SpeakerRepository.canonicalSelection(voices)!
        XCTAssertTrue(selection.voices.contains { $0.voice.meetingId == "long" }, "long meeting stays in")
        XCTAssertEqual(selection.dropped.count, 5)

        var everyoneVotes = SpeakerRepository.RecalcConfig.default
        everyoneVotes.outlierVoteFloorSeconds = 0
        let before = SpeakerRepository.canonicalSelection(voices, config: everyoneVotes)!
        XCTAssertTrue(before.dropped.contains { $0.meetingId == "long" }, "the behaviour this floor fixes")
    }

    /// Ни одна встреча не дотягивает до порога — голосуют все, как раньше.
    func testAllShortMeetingsStillVote() {
        var voices = (1 ... 5).map { voice("m\($0)", day: Double($0), emb: axis(0), sec: 30) }
        voices.append(voice("bad", day: 6, emb: axis(2), sec: 40))
        let selection = SpeakerRepository.canonicalSelection(voices)!
        XCTAssertTrue(selection.dropped.contains { $0.meetingId == "bad" })
    }

    /// 5.5: свежесть по дате встречи — давние вытесняются за лимитом.
    func testOldMeetingsDisplacedBeyondLimit() {
        var voices: [SpeakerRepository.MeetingVoice] = []
        for i in 0 ..< 5 { voices.append(voice("old\(i)", day: Double(i), emb: axis(0), sec: 60)) }
        for i in 0 ..< 3 { voices.append(voice("new\(i)", day: Double(100 + i), emb: axis(1), sec: 60)) }
        var cfg = SpeakerRepository.RecalcConfig.default
        cfg.maxMeetings = 3
        let canon = SpeakerRepository.canonicalFromVoices(voices, config: cfg)!
        XCTAssertLessThan(abs(canon[0]), 1e-6, "давние встречи вытеснены за лимитом")
        XCTAssertGreaterThan(canon[1], 0.99)
    }

    /// segment-own-voice § 6: a 5 s rescued piece weighs its 5 s, not as much
    /// as the 300 s cluster beside it.
    func testPerMeetingVoiceWeighsBySeconds() async throws {
        let db = try makeTestDB()
        let repo = SpeakerRepository(db: db)
        let meetingRepo = MeetingRepository(db: db)
        let meeting = makeMeeting()
        try await meetingRepo.save(meeting)
        let speaker = makeSpeaker(name: "Сергей")
        try await repo.save(speaker)

        var cluster = [Float](repeating: 0, count: 256)
        cluster[0] = 1
        var rescued = [Float](repeating: 0, count: 256)
        rescued[1] = 1
        var long = makeSegment(meetingId: meeting.id, speakerId: speaker.id, speakerLabel: "Сергей",
                               source: .system, startTime: 0, endTime: 300)
        long.embedding = Speaker.encodeEmbedding(cluster)
        var piece = makeSegment(meetingId: meeting.id, speakerId: speaker.id, speakerLabel: "Сергей",
                                source: .system, startTime: 300, endTime: 305)
        piece.embedding = Speaker.encodeEmbedding(rescued)
        try await meetingRepo.saveSegments([long, piece])

        let voices = try await repo.perMeetingVoices(speakerId: speaker.id, space: .v1)
        XCTAssertEqual(voices.count, 1)
        XCTAssertGreaterThanOrEqual(cosine(voices[0].embedding, cluster), 0.99)
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let na = a.reduce(0) { $0 + $1 * $1 }.squareRoot(), nb = b.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return dot / (na * nb)
    }
}
