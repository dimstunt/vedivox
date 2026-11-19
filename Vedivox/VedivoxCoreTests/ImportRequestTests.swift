import XCTest

/// The meeting date an import carries: accepted formats and the
/// date-only → midday-local convention.
final class ImportRequestTests: XCTestCase {

    func testParseISO8601DateTime() {
        XCTAssertEqual(
            ImportRequest.parseDate("2026-07-10T15:30:00Z"),
            ISO8601DateFormatter().date(from: "2026-07-10T15:30:00Z")
        )
    }

    func testGarbageDateIsNil() {
        XCTAssertNil(ImportRequest.parseDate("next-tuesday"))
        XCTAssertNil(ImportRequest.parseDate(""))
    }

    func testDateOnlyLandsMiddayLocal() throws {
        let date = try XCTUnwrap(ImportRequest.parseDate("2026-07-10"))
        let comps = Calendar.current.dateComponents([.day, .hour], from: date)
        XCTAssertEqual(comps.day, 10)
        XCTAssertEqual(comps.hour, 12)
    }

    func testDateOnlyMiddayAcrossDSTTransition() throws {
        // EU spring-forward day: midnight + 12 absolute hours would land on
        // 13:00 local; bySettingHour keeps noon on every calendar day.
        // Pinned: in the machine's own zone the day may have no transition at all.
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let date = try XCTUnwrap(ImportRequest.parseDate("2026-03-29", timeZone: berlin))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        let comps = calendar.dateComponents([.day, .hour], from: date)
        XCTAssertEqual(comps.day, 29)
        XCTAssertEqual(comps.hour, 12)
    }

    /// Egypt goes to summer time at 00:00: 24 April 2026 has no midnight
    /// there, and the date-only format used to answer nil — `vedivox import
    /// --date 2026-04-24` was refused as an unreadable date.
    func testDateOnlyOnADayWithoutMidnight() throws {
        let cairo = try XCTUnwrap(TimeZone(identifier: "Africa/Cairo"))
        let date = try XCTUnwrap(ImportRequest.parseDate("2026-04-24", timeZone: cairo))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = cairo
        let comps = calendar.dateComponents([.day, .hour], from: date)
        XCTAssertEqual(comps.day, 24)
        XCTAssertEqual(comps.hour, 12)
        XCTAssertNil(ImportRequest.parseDate("2026-04-24T", timeZone: cairo))
    }

    func testParseFractionalSecondsISO8601() {
        // JS Date.toISOString() output — advertised as ISO8601 by the tools.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            ImportRequest.parseDate("2026-07-10T15:30:00.500Z"),
            isoFractional.date(from: "2026-07-10T15:30:00.500Z")
        )
    }

    func testParseTimezoneLessDateTimeAsLocal() throws {
        // Python datetime.isoformat() output — no timezone designator.
        let date = try XCTUnwrap(ImportRequest.parseDate("2026-07-10T15:30:00"))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 10)
        XCTAssertEqual(comps.hour, 15)
        XCTAssertEqual(comps.minute, 30)
    }
}
