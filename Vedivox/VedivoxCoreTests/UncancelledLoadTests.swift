import XCTest

/// A list is loaded for whoever shows it, not for the task that asked. SwiftUI
/// cancels a view's `.task` whenever it drops the view — the window reopened
/// during a slow launch, a section left while it loads — and GRDB fails a read
/// from a cancelled task with CancellationError.
final class UncancelledLoadTests: XCTestCase {
    private var meetings: MeetingRepository!

    override func setUp() async throws {
        meetings = MeetingRepository(db: try makeTestDB())
        try await meetings.save(makeMeeting(title: "kept"))
    }

    /// What the callers were exposed to: the read itself refuses.
    func testAReadFromACancelledTaskIsRefused() async throws {
        let repo = try XCTUnwrap(meetings)
        let cancelled = Task { () -> [Meeting] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repo.all()
        }

        do {
            _ = try await cancelled.value
            XCTFail("GRDB is expected to refuse a read from a cancelled task")
        } catch is CancellationError {}
    }

    func testAnUncancelledLoadAnswersACancelledCaller() async throws {
        let repo = try XCTUnwrap(meetings)
        let cancelled = Task { () -> [Meeting] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await uncancelled { try await repo.all() }
        }

        let rows = try await cancelled.value

        XCTAssertEqual(rows.map(\.title), ["kept"])
    }

    func testAnUncancelledLoadStillReportsItsOwnFailure() async throws {
        struct Broken: Error {}
        do {
            _ = try await uncancelled { () -> Int in throw Broken() }
            XCTFail("the load's own error must reach the caller")
        } catch is Broken {}
    }
}
