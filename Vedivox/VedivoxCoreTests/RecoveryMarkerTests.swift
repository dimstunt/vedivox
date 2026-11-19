import XCTest

/// A recovery cut short by a quit runs again; one that died does not.
final class RecoveryMarkerTests: XCTestCase {
    private func marker() -> RecoveryMarker {
        RecoveryMarker(defaults: UserDefaults(suiteName: "RecoveryMarkerTests-\(UUID().uuidString)")!)
    }

    func testNeverStartedIsNotAFailure() {
        XCTAssertFalse(marker().diedDuring("A"))
    }

    /// A crash or a kill leaves the mark: the next launch gives up on the meeting, once.
    func testDiedDuringRecovery() {
        let marker = marker()
        marker.begin("A")
        XCTAssertFalse(marker.diedDuring("B"))
        XCTAssertTrue(marker.diedDuring("A"))
        XCTAssertFalse(marker.diedDuring("A"), "the mark is spent: Reprocess must not hit it again")
    }

    /// What died stays known after the mark is spent: the «not processed»
    /// banner leaves that meeting out.
    func testCrashedMeetingStaysKnown() {
        let marker = marker()
        marker.begin("A")
        XCTAssertEqual(marker.crashed, [], "only the launch that finds the mark knows it died")
        XCTAssertTrue(marker.diedDuring("A"))
        marker.begin("B")
        marker.end()
        XCTAssertEqual(marker.crashed, ["A"])
    }

    func testFinishedRecovery() {
        let marker = marker()
        marker.begin("A")
        marker.end()
        XCTAssertFalse(marker.diedDuring("A"))
    }

    /// Quit, logout or restart mid-recovery: the app terminates normally and drops the mark.
    func testQuitDuringRecoveryRunsItAgain() {
        let defaults = UserDefaults(suiteName: "RecoveryMarkerTests-\(UUID().uuidString)")!
        RecoveryMarker(defaults: defaults).begin("A")
        RecoveryMarker(defaults: defaults).end() // applicationWillTerminate
        XCTAssertFalse(RecoveryMarker(defaults: defaults).diedDuring("A"))
    }
}
