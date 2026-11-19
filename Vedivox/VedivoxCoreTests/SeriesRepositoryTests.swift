import XCTest
import GRDB

final class SeriesRepositoryTests: XCTestCase {

    private var db: DatabaseManager!
    private var repo: SeriesRepository!
    private var meetingRepo: MeetingRepository!

    override func setUp() async throws {
        db = try makeTestDB()
        repo = SeriesRepository(db: db)
        meetingRepo = MeetingRepository(db: db)
    }

    func testSaveSeries() async throws {
        let series = MeetingSeries(name: "Weekly Standup", calendarSeriesId: "cal-123")
        try await repo.save(series)

        let fetched = try await repo.find(series.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Weekly Standup")
        XCTAssertEqual(fetched?.calendarSeriesId, "cal-123")
    }

    func testFindByCalendarSeriesId() async throws {
        let series = MeetingSeries(name: "Sprint Review", calendarSeriesId: "cal-456")
        try await repo.save(series)

        let found = try await repo.findByCalendarSeriesId("cal-456")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, series.id)

        let notFound = try await repo.findByCalendarSeriesId("nonexistent")
        XCTAssertNil(notFound)
    }

    func testDeleteSeries_nullifiesMeetings() async throws {
        let series = MeetingSeries(name: "Weekly")
        try await repo.save(series)

        let m1 = makeMeeting(title: "M1", seriesId: series.id)
        let m2 = makeMeeting(title: "M2", seriesId: series.id)
        try await meetingRepo.save(m1)
        try await meetingRepo.save(m2)

        try await repo.delete(series)

        // Series is gone
        let fetchedSeries = try await repo.find(series.id)
        XCTAssertNil(fetchedSeries)

        // Meetings still exist but seriesId is NULL
        let f1 = try await meetingRepo.find(m1.id)
        let f2 = try await meetingRepo.find(m2.id)
        XCTAssertNotNil(f1)
        XCTAssertNotNil(f2)
        XCTAssertNil(f1?.seriesId)
        XCTAssertNil(f2?.seriesId)
    }

    /// option A: a duplicate is folded into the series that stays.
    func testMerge_movesMeetingsFillsEmptyFieldsAndDeletesSource() async throws {
        let target = MeetingSeries(name: "Weekly sync", calendarSeriesId: "cal-old", autoRulePattern: "^Weekly")
        let source = MeetingSeries(name: "Sync, weekly", calendarSeriesId: "cal-new", icon: "person.2")
        let other = MeetingSeries(name: "Other")
        for series in [target, source, other] { try await repo.save(series) }
        let moved = makeMeeting(title: "M1", seriesId: source.id)
        let stays = makeMeeting(title: "M2", seriesId: target.id)
        let untouched = makeMeeting(title: "M3", seriesId: other.id)
        for meeting in [moved, stays, untouched] { try await meetingRepo.save(meeting) }

        let result = try await repo.merge(source.id, into: target.id)

        XCTAssertEqual(result?.moved, 1)
        XCTAssertEqual(result?.droppedCalendarId, "cal-new", "both linked: the target's link stays")
        let fetchedSource = try await repo.find(source.id)
        XCTAssertNil(fetchedSource)
        let merged = try await repo.find(target.id)
        XCTAssertEqual(merged?.name, "Weekly sync")
        XCTAssertEqual(merged?.calendarSeriesId, "cal-old")
        XCTAssertEqual(merged?.autoRulePattern, "^Weekly")
        XCTAssertEqual(merged?.icon, "person.2", "an empty field is taken from the source")
        let m1 = try await meetingRepo.find(moved.id)
        let m3 = try await meetingRepo.find(untouched.id)
        XCTAssertEqual(m1?.seriesId, target.id)
        XCTAssertEqual(m3?.seriesId, other.id)
    }

    func testMerge_unlinkedTargetTakesTheCalendarLink() async throws {
        let target = MeetingSeries(name: "Design review")
        let source = MeetingSeries(name: "Design review", calendarSeriesId: "cal-new")
        for series in [target, source] { try await repo.save(series) }

        let result = try await repo.merge(source.id, into: target.id)

        XCTAssertNil(result?.droppedCalendarId)
        let merged = try await repo.find(target.id)
        XCTAssertEqual(merged?.calendarSeriesId, "cal-new")
    }

    func testMerge_unknownOrSameSeriesChangesNothing() async throws {
        let series = MeetingSeries(name: "Weekly")
        try await repo.save(series)
        let meeting = makeMeeting(title: "M1", seriesId: series.id)
        try await meetingRepo.save(meeting)

        let missing = try await repo.merge("nope", into: series.id)
        let same = try await repo.merge(series.id, into: series.id)
        XCTAssertNil(missing)
        XCTAssertNil(same)
        let fetched = try await meetingRepo.find(meeting.id)
        XCTAssertEqual(fetched?.seriesId, series.id)
    }

    // MARK: - One series per name

    func testFindAdoptableByName_caseInsensitiveLatin() async throws {
        try await repo.save(MeetingSeries(name: "Design Board"))

        let found = try await repo.findAdoptableByName("design board")
        XCTAssertEqual(found?.name, "Design Board")
    }

    func testFindAdoptableByName_caseInsensitiveCyrillic() async throws {
        try await repo.save(MeetingSeries(name: "Синк по Дизайну"))

        let found = try await repo.findAdoptableByName("синк по дизайну")
        XCTAssertNotNil(found, "SQLite NOCASE misses Cyrillic — comparison must fold it")
    }

    func testFindAdoptableByName_trimsWhitespace() async throws {
        try await repo.save(MeetingSeries(name: "Weekly Sync"))

        let found = try await repo.findAdoptableByName("  Weekly Sync ")
        XCTAssertNotNil(found)
    }

    func testCreateOrReuse_sameNameReturnsExisting() async throws {
        let first = try await repo.createOrReuse(MeetingSeries(name: "Клуб"))
        let second = try await repo.createOrReuse(MeetingSeries(name: " клуб"))

        XCTAssertTrue(first.created)
        XCTAssertFalse(second.created)
        XCTAssertEqual(second.series.id, first.series.id)
        let count = try await repo.all().count
        XCTAssertEqual(count, 1)
    }

    func testFindAdoptableByName_skipsCalendarLinkedSeries() async throws {
        try await repo.save(MeetingSeries(name: "Design Board", calendarSeriesId: "cal-1"))

        let found = try await repo.findAdoptableByName("Design Board")
        XCTAssertNil(found, "a series already linked to a calendar id is not adoptable")
    }

    func testSetCalendarSeriesId_linksSeries() async throws {
        let series = MeetingSeries(name: "Design Board")
        try await repo.save(series)

        try await repo.setCalendarSeriesId(series.id, "cal-42")

        let byCal = try await repo.findByCalendarSeriesId("cal-42")
        XCTAssertEqual(byCal?.id, series.id)
        // Adopted series is no longer adoptable
        let adoptable = try await repo.findAdoptableByName("Design Board")
        XCTAssertNil(adoptable)
    }

    // MARK: - Calendar series

    private func event(_ title: String, id: String, recurring: Bool = true) -> CalendarService.CalendarEvent {
        CalendarService.CalendarEvent(
            title: title, startDate: Date(), endDate: Date(),
            calendarItemIdentifier: id, hasRecurrenceRules: recurring
        )
    }

    func testResolveCalendarSeries_oneOffEventCreatesNothing() async throws {
        let series = try await repo.resolveCalendarSeries(for: event("Interview", id: "cal-1", recurring: false))

        XCTAssertNil(series)
        let count = try await repo.all().count
        XCTAssertEqual(count, 0)
    }

    func testResolveCalendarSeries_sameEventSameSeries() async throws {
        let first = try await repo.resolveCalendarSeries(for: event("Daily", id: "cal-1"))
        let second = try await repo.resolveCalendarSeries(for: event("Daily", id: "cal-1"))

        XCTAssertEqual(second?.id, first?.id)
        let count = try await repo.all().count
        XCTAssertEqual(count, 1)
    }

    func testResolveCalendarSeries_adoptsUnlinkedSeriesByName() async throws {
        let manual = MeetingSeries(name: "Design Board")
        try await repo.save(manual)

        let resolved = try await repo.resolveCalendarSeries(for: event("design board", id: "cal-1"))

        XCTAssertEqual(resolved?.id, manual.id)
        XCTAssertEqual(resolved?.calendarSeriesId, "cal-1")
    }

    func testResolveCalendarSeries_otherEventWithSameNameGetsOwnSeries() async throws {
        let linked = MeetingSeries(name: "1:1", calendarSeriesId: "cal-a")
        try await repo.save(linked)

        let resolved = try await repo.resolveCalendarSeries(for: event("1:1", id: "cal-b"))

        XCTAssertNotEqual(resolved?.id, linked.id, "same title is not proof of the same call")
        let kept = try await repo.findByCalendarSeriesId("cal-a")
        XCTAssertEqual(kept?.id, linked.id)
    }

    // MARK: - Series on creation, not only on rename

    /// the preview counts what the apply takes; meetings already in a
    /// series are neither counted nor moved.
    func testRetroMatches_countsWhatApplyAssigns() async throws {
        let other = MeetingSeries(name: "Other")
        let series = MeetingSeries(name: "Weekly", autoRulePattern: "^weekly")
        try await repo.save(other)
        try await repo.save(series)
        try await meetingRepo.save(makeMeeting(title: "weekly sync 1"))
        try await meetingRepo.save(makeMeeting(title: "Weekly sync 2"))
        try await meetingRepo.save(makeMeeting(title: "weekly but taken", seriesId: other.id))
        try await meetingRepo.save(makeMeeting(title: "retro"))

        let preview = try await repo.retroMatches(series)
        let assigned = try await repo.applyRuleRetroactively(series)
        let again = try await repo.applyRuleRetroactively(series)

        XCTAssertEqual(assigned, 2)
        XCTAssertEqual(preview.count, assigned)
        XCTAssertEqual(again, 0)
        let taken = try await repo.retroMatches(MeetingSeries(name: "x", autoRulePattern: "taken"))
        XCTAssertTrue(taken.isEmpty)
    }

    /// AC5: one pass over the archive, first matching series wins
    /// (as for a new meeting); a dry run changes nothing.
    func testApplyAllRules_firstMatchWinsAndDryRunWritesNothing() async throws {
        let alpha = MeetingSeries(name: "Alpha", autoRulePattern: "sync")
        let beta = MeetingSeries(name: "Beta", autoRulePattern: "weekly")
        try await repo.save(alpha)
        try await repo.save(beta)
        let both = makeMeeting(title: "weekly sync")
        let onlyBeta = makeMeeting(title: "weekly review")
        let none = makeMeeting(title: "lunch")
        for m in [both, onlyBeta, none] { try await meetingRepo.save(m) }

        let preview = try await repo.applyAllRules(dryRun: true)
        let unchanged = try await meetingRepo.find(both.id)
        let applied = try await repo.applyAllRules(dryRun: false)

        XCTAssertNil(unchanged?.seriesId)
        XCTAssertEqual(preview.map(\.count), applied.map(\.count))
        XCTAssertEqual(applied.map(\.series.name), ["Alpha", "Beta"])
        XCTAssertEqual(applied.map(\.count), [1, 1])
        let bothAfter = try await meetingRepo.find(both.id)
        let noneAfter = try await meetingRepo.find(none.id)
        XCTAssertEqual(bothAfter?.seriesId, alpha.id)
        XCTAssertNil(noneAfter?.seriesId)
    }

    func testCreateMeeting_appliesAutoRule() async throws {
        let series = MeetingSeries(name: "Standup", autoRulePattern: "stand-?up")
        try await repo.save(series)

        let meeting = makeMeeting(title: "Daily Standup")
        try await meetingRepo.create(meeting)

        let stored = try await meetingRepo.find(meeting.id)
        XCTAssertEqual(stored?.seriesId, series.id)
    }

    func testCreateMeeting_keepsGivenSeries() async throws {
        let ruled = MeetingSeries(name: "Standup", autoRulePattern: "standup")
        let calendar = MeetingSeries(name: "Calendar", calendarSeriesId: "cal-1")
        try await repo.save(ruled)
        try await repo.save(calendar)

        let meeting = makeMeeting(title: "Daily Standup", seriesId: calendar.id)
        try await meetingRepo.create(meeting)

        let stored = try await meetingRepo.find(meeting.id)
        XCTAssertEqual(stored?.seriesId, calendar.id)
    }
}
