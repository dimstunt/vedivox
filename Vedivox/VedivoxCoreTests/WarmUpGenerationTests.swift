import XCTest

/// Pins the rule that keeps stale warm-up progress off the screen (
/// an earlier change, spec `model-loading` — «Показанный
/// прогресс относится к текущему заходу»).
///
/// The timing half of that change — revealing the banner only after 500 ms —
/// is deliberately not tested here: asserting on a delay measures the
/// scheduler, not the decision. This suite covers the part that holds
/// regardless of when a report arrives.
final class WarmUpGenerationTests: XCTestCase {

    func testReportFromCurrentRunIsAccepted() {
        var generation = WarmUpGeneration()
        let token = generation.begin()

        XCTAssertTrue(generation.accepts(token))
    }

    /// The failure this change is about: a report produced by the previous run
    /// arriving after a new one started.
    func testReportFromPreviousRunIsRejected() {
        var generation = WarmUpGeneration()
        let first = generation.begin()
        let second = generation.begin()

        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))
    }

    /// A finished run accepts nothing, including its own late reports — that is
    /// what leaves the progress state empty after warm-up.
    func testFinishedRunAcceptsNothing() {
        var generation = WarmUpGeneration()
        let token = generation.begin()
        generation.end(token)

        XCTAssertFalse(generation.accepts(token))
        XCTAssertNil(generation.activeToken)
    }

    /// «Повторить» while a previous run is still unwinding: the retry owns the
    /// state, and the older run finishing must not clear it out from under it.
    func testEndingSupersededRunLeavesCurrentRunActive() {
        var generation = WarmUpGeneration()
        let first = generation.begin()
        let second = generation.begin()

        generation.end(first)

        XCTAssertTrue(generation.accepts(second))
        XCTAssertEqual(generation.activeToken, second)
    }

    func testTokensAreNotReused() {
        var generation = WarmUpGeneration()
        let first = generation.begin()
        generation.end(first)
        let second = generation.begin()

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(generation.accepts(first))
    }
}
