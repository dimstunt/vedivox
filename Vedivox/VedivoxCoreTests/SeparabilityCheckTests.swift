import XCTest

/// Voice `index` of `count` lookalike voices of one speaker next to a neighbour
/// on axis 0: every voice shares a common part of squared length `s` and has
/// its own noise axis, and the canonical of all `count` (equal weights) sits
/// at `canonSim` to the neighbour. Smaller `s` — noisier voices, smaller gap.
func lookalikeVoice(index: Int, s: Float, canonSim: Float, count: Int, dim: Int) -> [Float] {
    let n = Float(count)
    let a = canonSim * (n * (n - 1) * s + n).squareRoot() / n
    var v = [Float](repeating: 0, count: dim)
    v[0] = a
    v[1] = (s - a * a).squareRoot()
    v[2 + index] = (1 - s).squareRoot()
    return v
}

/// Pure tests of the identity invariant by separability
/// (separability-invariant, design § 1–2).
final class SeparabilityCheckTests: XCTestCase {

    private let dim = 32
    private let neighbor = SeparabilityCheck.Neighbor(
        id: "b", name: "B", canonical: [1] + [Float](repeating: 0, count: 31)
    )

    /// Every voice stays: the test controls the set, not the outlier filter.
    private var config: SpeakerRepository.RecalcConfig {
        var config = SpeakerRepository.RecalcConfig.default
        config.keepFraction = 1
        return config
    }

    private func voice(_ id: String, _ embedding: [Float], seconds: Double = 60) -> SpeakerRepository.MeetingVoice {
        SpeakerRepository.MeetingVoice(
            meetingId: id, meetingStart: Date(timeIntervalSince1970: 0),
            embedding: embedding, speechSeconds: seconds
        )
    }

    private func lookalikes(_ count: Int, s: Float, of total: Int = 9) -> [SpeakerRepository.MeetingVoice] {
        (0 ..< count).map {
            voice("m\($0)", lookalikeVoice(index: $0, s: s, canonSim: 0.78, count: total, dim: dim))
        }
    }

    private func evaluate(_ voices: [SpeakerRepository.MeetingVoice]) -> (SeparabilityCheck.Result, [Float]) {
        let selection = SpeakerRepository.canonicalSelection(voices, config: config)!
        XCTAssertEqual(selection.voices.count, voices.count)
        let result = SeparabilityCheck.evaluate(selection, neighbors: [neighbor], config: config, space: .v2)
        return (result, selection.canonical)
    }

    /// Честный двойник: слепок на 0.78 к соседу, отрыв 0.08 у каждого голоса.
    func testLookalikeWithClearGapsAccepted() {
        let (result, canonical) = evaluate(lookalikes(9, s: 0.485))
        XCTAssertEqual(cosineSimilarity(canonical, neighbor.canonical), 0.78, accuracy: 0.005)
        XCTAssertEqual(result.gaps.count, 9)
        for gap in result.gaps { XCTAssertEqual(gap.gap, 0.08, accuracy: 0.005) }
        XCTAssertEqual(result.verdict, .separable)
    }

    /// 2 из 9 голосов на 30 % речи ближе к соседу — отказ называет обе встречи.
    func testPoisonedMeetingsRejectedAndNamed() {
        var voices = lookalikes(7, s: 0.485)
        for (index, seconds) in [(20, 100.0), (21, 80.0)] {
            var poisoned = [Float](repeating: 0, count: dim)
            poisoned[0] = 0.9
            poisoned[index] = Float(0.19).squareRoot()
            voices.append(voice("bad\(index)", poisoned, seconds: seconds))
        }
        let (result, _) = evaluate(voices)
        guard case .inseparable(let id, let name, _, let share, let meetings) = result.verdict else {
            return XCTFail("expected inseparable, got \(result.verdict)")
        }
        XCTAssertEqual(id, "b")
        XCTAssertEqual(name, "B")
        XCTAssertEqual(share, 0.30, accuracy: 0.001)
        XCTAssertEqual(meetings, ["bad20", "bad21"], "offending meetings, most speech first")
        XCTAssertEqual(result.negativeShare, 2.0 / 9, accuracy: 0.001)
        XCTAssertTrue(result.logDescription.contains("meeting bad20 (100s)"), result.logDescription)
    }

    /// Встречи, которые отбор выбросов не пустил в слепок, всё равно судятся:
    /// чужая встреча под этим спикером — как раз то, что отбор отбрасывает.
    func testMeetingsDroppedByOutlierFilterAreStillJudged() {
        var voices = (0 ..< 6).map {
            voice("m\($0)", lookalikeVoice(index: $0, s: 0.8, canonSim: 0.6, count: 9, dim: dim))
        }
        for (index, seconds) in [(20, 100.0), (21, 80.0)] {
            var poisoned = [Float](repeating: 0, count: dim)
            poisoned[0] = 0.9
            poisoned[index] = Float(0.19).squareRoot()
            voices.append(voice("bad\(index)", poisoned, seconds: seconds))
        }
        let selection = SpeakerRepository.canonicalSelection(voices)!
        XCTAssertEqual(selection.voices.count, 4, "default filter keeps half")
        XCTAssertEqual(Set(selection.dropped.map(\.meetingId)).intersection(["bad20", "bad21"]).count, 2)
        let result = SeparabilityCheck.evaluate(selection, neighbors: [neighbor], config: .default, space: .v2)
        XCTAssertEqual(result.gaps.count, 8)
        guard case .inseparable(_, _, _, let share, let meetings) = result.verdict else {
            return XCTFail("expected inseparable, got \(result.verdict)")
        }
        XCTAssertEqual(meetings, ["bad20", "bad21"])
        XCTAssertEqual(share, 180.0 / 540, accuracy: 0.001)
        XCTAssertGreaterThan(result.medianGap ?? 0, 0.05, "rejected by the offending meetings, not the median")
    }

    /// Ни одного голоса ближе к соседу, но медиана отрыва 0.03 — отказ.
    func testSmallMedianGapRejected() {
        let (result, _) = evaluate(lookalikes(9, s: 0.36))
        XCTAssertEqual(result.medianGap ?? 0, 0.03, accuracy: 0.005)
        XCTAssertEqual(result.negativeShare, 0)
        guard case .inseparable(_, let name, _, _, let meetings) = result.verdict else {
            return XCTFail("expected inseparable, got \(result.verdict)")
        }
        XCTAssertEqual(name, "B")
        XCTAssertTrue(meetings.isEmpty)
    }

    /// Слепки на 0.91 — отказ, хотя каждый голос отстоит от соседа на 0.09.
    func testHardCapRejectsWhateverTheGaps() {
        var v = [Float](repeating: 0, count: dim)
        v[0] = 0.91
        v[1] = (1 - 0.91 * 0.91).squareRoot()
        let (result, _) = evaluate((0 ..< 9).map { voice("m\($0)", v) })
        XCTAssertEqual(result.medianGap ?? 0, 0.09, accuracy: 0.001)
        guard case .tooSimilar(_, let name, let sim) = result.verdict else {
            return XCTFail("expected tooSimilar, got \(result.verdict)")
        }
        XCTAssertEqual(name, "B")
        XCTAssertEqual(sim, 0.91, accuracy: 0.001)
    }

    /// Меньше трёх голосов — прежний порог 0.75 между слепками.
    func testFewVoicesFallBackToPlainThreshold() {
        func two(_ cos: Float) -> [SpeakerRepository.MeetingVoice] {
            var v = [Float](repeating: 0, count: dim)
            v[0] = cos
            v[1] = (1 - cos * cos).squareRoot()
            return [voice("m0", v), voice("m1", v)]
        }
        guard case .tooSimilar = evaluate(two(0.78)).0.verdict else { return XCTFail("0.78 must be rejected") }
        XCTAssertEqual(evaluate(two(0.70)).0.verdict, .separable)
    }

    /// Фильтр соседей: далёкая колонка не проверяется, близких — не больше пяти.
    func testShortlistKeepsOnlyCloseColumnsUpToLimit() {
        let selection = SpeakerRepository.canonicalSelection(lookalikes(9, s: 0.485), config: config)!
        var far = [Float](repeating: 0, count: dim)
        far[31] = 1
        var columns = [SeparabilityCheck.Neighbor(id: "far", name: "Far", canonical: far)]
        for i in 0 ..< 7 {
            columns.append(SeparabilityCheck.Neighbor(id: "near\(i)", name: "Near", canonical: neighbor.canonical))
        }
        let picked = SeparabilityCheck.shortlist(selection, columns: columns, config: config.separability)
        XCTAssertEqual(picked.count, 5)
        XCTAssertFalse(picked.contains { $0.id == "far" })
    }
}
