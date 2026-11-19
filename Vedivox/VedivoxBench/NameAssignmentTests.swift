import XCTest

/// Synthetic checks for the name-assignment metric — no audio, milliseconds:
///
///     xcodebuild test -project Vedivox/Vedivox.xcodeproj -scheme VedivoxBench \
///       -only-testing:VedivoxBench/NameAssignmentTests
final class NameAssignmentTests: XCTestCase {
    private func seg(_ start: Double, _ end: Double, _ key: String) -> DERScorer.Segment {
        DERScorer.Segment(start: start, end: end, key: key)
    }

    /// Bench M5 shape: a newcomer lands on an old record — wrong name, while a
    /// freshly minted record for another newcomer is not counted at all.
    func testNewcomerOnExistingRecordIsFalseAssignment() {
        let result = NameAssignment.score(
            predicted: [seg(0, 40, "nina-id"), seg(40, 100, "speaker-new")],
            reference: [seg(0, 40, "Клара"), seg(40, 100, "Ирма")],
            identities: ["nina-id": "Нина"],
            existing: ["nina-id"]
        )
        XCTAssertEqual(result.rightSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(result.wrongSeconds, 40, accuracy: 1e-9)
        XCTAssertEqual(result.falseAssignments, 1)
        XCTAssertEqual(result.assignedRecords, 1)
    }

    /// A correct match with a little foreign speech inside is right overall:
    /// the dominant speaker decides the assignment, seconds are split honestly.
    func testCorrectMatchWithForeignTailIsNotFalseAssignment() {
        let result = NameAssignment.score(
            predicted: [seg(0, 50, "gleb-id")],
            reference: [seg(0, 45, "Глеб"), seg(45, 50, "Фома")],
            identities: ["gleb-id": "Глеб"],
            existing: ["gleb-id"]
        )
        XCTAssertEqual(result.rightSeconds, 45, accuracy: 1e-9)
        XCTAssertEqual(result.wrongSeconds, 5, accuracy: 1e-9)
        XCTAssertEqual(result.falseAssignments, 0)
    }

    func testDominantSpeakerTieBreaksByName() {
        let dominant = NameAssignment.dominantSpeakers(
            predicted: [seg(0, 10, "k")],
            reference: [seg(0, 5, "Б"), seg(5, 10, "А")]
        )
        XCTAssertEqual(dominant["k"], "А")
    }
}
