import XCTest

final class SeriesAutoRuleTests: XCTestCase {

    private func series(_ name: String, pattern: String?) -> MeetingSeries {
        MeetingSeries(name: name, autoRulePattern: pattern)
    }

    func testCaseInsensitiveSubstringMatch() {
        let candidates = [
            series("Design Review", pattern: "design review"),
            series("1:1 Иван", pattern: #"1:1.*Иван"#),
        ]
        XCTAssertEqual(
            SeriesAutoRule.matchingSeries(title: "Design Review Weekly", in: candidates)?.name,
            "Design Review"
        )
        XCTAssertEqual(
            SeriesAutoRule.matchingSeries(title: "Регулярная 1:1 с Иван Сидоров", in: candidates)?.name,
            "1:1 Иван"
        )
        XCTAssertNil(SeriesAutoRule.matchingSeries(title: "Random Zoom", in: candidates))
    }

    func testInvalidAndEmptyPatternsAreSkipped() {
        let candidates = [
            series("Broken", pattern: "([unclosed"),
            series("Empty", pattern: "   "),
            series("NilRule", pattern: nil),
            series("Valid", pattern: "sync"),
        ]
        XCTAssertEqual(
            SeriesAutoRule.matchingSeries(title: "Product launch sync", in: candidates)?.name,
            "Valid"
        )
    }

    func testFirstMatchWins() {
        let candidates = [
            series("A", pattern: "weekly"),
            series("B", pattern: "data.*weekly"),
        ]
        XCTAssertEqual(
            SeriesAutoRule.matchingSeries(title: "Data Weekly", in: candidates)?.name,
            "A"
        )
    }

    func testPatternValidation() {
        XCTAssertTrue(SeriesAutoRule.isValidPattern("1:1.*"))
        XCTAssertFalse(SeriesAutoRule.isValidPattern("([broken"))
        XCTAssertFalse(SeriesAutoRule.isValidPattern("  "))
    }
}
