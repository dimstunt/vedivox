import XCTest

/// The window's limits on Split and Trim, asked by the socket commands
/// (cli-meeting-edit, design § 3).
final class MeetingEditCheckTests: XCTestCase {
    private let lines: [(start: Double, end: Double)] = [(0, 10), (20, 30), (50, 58)]

    func testSplitNeedsACutInsideAndLinesOnBothSides() {
        XCTAssertNil(MeetingEditCheck.split(at: 20, duration: 60, segments: lines))
        XCTAssertNil(MeetingEditCheck.split(at: 25, duration: 60, segments: lines), "a line across the cut stays in part 1")
        XCTAssertNotNil(MeetingEditCheck.split(at: 0.5, duration: 60, segments: lines), "closer than 1 s to the start")
        XCTAssertNotNil(MeetingEditCheck.split(at: 59.5, duration: 60, segments: lines), "closer than 1 s to the end")
        XCTAssertNotNil(MeetingEditCheck.split(at: 55, duration: 60, segments: lines), "nothing starts after the cut")
        XCTAssertNotNil(MeetingEditCheck.split(at: 30, duration: 60, segments: []), "no lines at all")
        XCTAssertNotNil(MeetingEditCheck.split(at: 0.5, duration: 1, segments: lines), "too short")
    }

    func testTrimMustCutSomethingAndKeepALine() {
        XCTAssertNil(MeetingEditCheck.trim(from: 15, to: 60, duration: 60, segments: lines))
        XCTAssertNil(MeetingEditCheck.trim(from: 0, to: 25, duration: 60, segments: lines))
        XCTAssertNotNil(MeetingEditCheck.trim(from: 0, to: 60, duration: 60, segments: lines), "nothing cut off")
        XCTAssertNotNil(MeetingEditCheck.trim(from: 10, to: 10.5, duration: 60, segments: lines), "less than 1 s kept")
        XCTAssertNotNil(MeetingEditCheck.trim(from: 5, to: 70, duration: 60, segments: lines), "past the end")
        XCTAssertNotNil(MeetingEditCheck.trim(from: 31, to: 49, duration: 60, segments: lines), "no line in the kept range")
    }
}
