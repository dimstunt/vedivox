import XCTest

/// Review 3, 4, 6 of cli-meeting-edit: one meeting edit at a time, none before the launch recovery.
final class MeetingEditLockTests: XCTestCase {
    func testOneEditAtATimeAndNoneBeforeTheRecovery() {
        var lock = MeetingEditLock()
        XCTAssertFalse(lock.begin(["a"]), "taken from launch until the recovery lets it go")
        lock.end()

        XCTAssertTrue(lock.begin(["a", "b"]))
        XCTAssertFalse(lock.begin(["c"]), "a second edit waits")
        lock.add(["d"])
        XCTAssertEqual(lock.meetingIds, ["a", "b", "d"])
        lock.end()
        XCTAssertTrue(lock.meetingIds.isEmpty)
        XCTAssertTrue(lock.begin(["c"]))
    }
}
