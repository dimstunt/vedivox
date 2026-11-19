import Foundation
import GRDB

struct SeriesRepository {
    private let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    func all() async throws -> [MeetingSeries] {
        try await db.reader.read { db in
            try MeetingSeries.order(Column("name").asc).fetchAll(db)
        }
    }

    func find(_ id: String) async throws -> MeetingSeries? {
        try await db.reader.read { db in
            try MeetingSeries.fetchOne(db, key: id)
        }
    }

    func findByCalendarSeriesId(_ calendarSeriesId: String) async throws -> MeetingSeries? {
        try await db.reader.read { db in
            try MeetingSeries.filter(Column("calendarSeriesId") == calendarSeriesId).fetchOne(db)
        }
    }

    /// A calendar-recurring event seen for the first time may correspond to a
    /// series the user already has (created before calendar integration or
    /// with a slightly different title case). Matching by name and adopting
    /// prevents duplicate series («Design Board» vs «Design board»).
    /// A series already linked to another event is not adopted: two calls
    /// titled «1:1» are different series.
    func findAdoptableByName(_ name: String) async throws -> MeetingSeries? {
        try await db.reader.read { db in
            try Self.named(name, in: MeetingSeries.filter(Column("calendarSeriesId") == nil).fetchAll(db))
        }
    }

    /// Case-insensitive, trimmed. Swift-side: SQLite NOCASE doesn't fold Cyrillic.
    private static func named(_ name: String, in candidates: [MeetingSeries]) -> MeetingSeries? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(target) == .orderedSame
        }
    }

    /// Manual creation (app, CLI): insert `series` unless one with the same name
    /// exists; returns the series that is in the database. One
    /// transaction, so two creates can't both miss.
    func createOrReuse(_ series: MeetingSeries) async throws -> (series: MeetingSeries, created: Bool) {
        try await db.writer.write { db in
            if let existing = Self.named(series.name, in: try MeetingSeries.fetchAll(db)) {
                return (existing, false)
            }
            try series.insert(db)
            return (series, true)
        }
    }

    /// Series of a recurring calendar event (nil for a one-off event): by
    /// calendar id, else an unlinked same-named series is adopted, else a new one.
    func resolveCalendarSeries(for event: CalendarService.CalendarEvent) async throws -> MeetingSeries? {
        guard event.hasRecurrenceRules else { return nil }
        let calItemId = event.calendarItemIdentifier
        if let existing = try await findByCalendarSeriesId(calItemId) { return existing }
        if var adoptable = try await findAdoptableByName(event.title) {
            try await setCalendarSeriesId(adoptable.id, calItemId)
            adoptable.calendarSeriesId = calItemId
            Log.info("Series '\(adoptable.name)' adopted calendar id \(calItemId) (was unlinked)")
            return adoptable
        }
        let series = MeetingSeries(name: event.title, calendarSeriesId: calItemId)
        try await save(series)
        return series
    }

    /// Link a series to its calendar recurring event.
    func setCalendarSeriesId(_ id: String, _ calendarSeriesId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meeting_series SET calendarSeriesId = ? WHERE id = ?",
                arguments: [calendarSeriesId, id]
            )
        }
    }

    func save(_ series: MeetingSeries) async throws {
        try await db.writer.write { db in
            try series.save(db)
        }
    }

    func delete(_ series: MeetingSeries) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET seriesId = NULL WHERE seriesId = ?",
                arguments: [series.id]
            )
            _ = try series.delete(db)
        }
    }

    /// Folds `sourceId` into `targetId` (option A: duplicates are
    /// merged by hand). The source's meetings move over, the target keeps its
    /// own fields and takes the source's only where its own are empty, and the
    /// source is deleted — one transaction. When both are linked to a calendar
    /// event, the target's link stays and the source's comes back as
    /// `droppedCalendarId`. Nil when either series does not exist.
    func merge(
        _ sourceId: String, into targetId: String
    ) async throws -> (target: MeetingSeries, source: MeetingSeries, moved: Int, droppedCalendarId: String?)? {
        try await db.writer.write { db in
            guard sourceId != targetId,
                  let source = try MeetingSeries.fetchOne(db, key: sourceId),
                  var target = try MeetingSeries.fetchOne(db, key: targetId) else { return nil }
            try db.execute(
                sql: "UPDATE meetings SET seriesId = ? WHERE seriesId = ?",
                arguments: [targetId, sourceId]
            )
            let moved = db.changesCount
            let dropped = target.calendarSeriesId != nil ? source.calendarSeriesId : nil
            target.calendarSeriesId = target.calendarSeriesId ?? source.calendarSeriesId
            target.hue = target.hue ?? source.hue
            target.icon = target.icon ?? source.icon
            target.seriesDescription = target.seriesDescription ?? source.seriesDescription
            target.autoRulePattern = target.autoRulePattern ?? source.autoRulePattern
            _ = try source.delete(db)
            try target.update(db)
            return (target, source, moved, dropped)
        }
    }

    // MARK: - Series detail page

    func seriesWithStats() async throws -> [SeriesInfo] {
        try await db.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, COUNT(m.id) AS meetingCount,
                       MAX(m.startTime) AS lastMeetingDate,
                       COALESCE(SUM(m.durationSeconds), 0) AS totalDurationSeconds
                FROM meeting_series s
                LEFT JOIN meetings m ON m.seriesId = s.id
                GROUP BY s.id
                ORDER BY s.name
                """)
            return try rows.map { row in
                SeriesInfo(
                    series: try MeetingSeries(row: row),
                    meetingCount: row["meetingCount"],
                    lastMeetingDate: row["lastMeetingDate"],
                    totalDurationSeconds: row["totalDurationSeconds"]
                )
            }
        }
    }

    func meetingsForSeries(_ seriesId: String) async throws -> [Meeting] {
        try await db.reader.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT * FROM meetings WHERE seriesId = ? ORDER BY startTime DESC
                """, arguments: [seriesId])
        }
    }

    /// Apply auto-rules to one meeting title. No-op when the meeting already
    /// belongs to a series. Returns the matched series when assigned.
    @discardableResult
    func applyAutoRule(meetingId: String, title: String) async throws -> MeetingSeries? {
        let allSeries = try await all()
        guard let match = SeriesAutoRule.matchingSeries(title: title, in: allSeries) else { return nil }
        let assigned: Bool = try await db.writer.write { db in
            let current = try String.fetchOne(
                db, sql: "SELECT seriesId FROM meetings WHERE id = ?", arguments: [meetingId]
            )
            guard current == nil else { return false }
            try db.execute(
                sql: "UPDATE meetings SET seriesId = ? WHERE id = ?",
                arguments: [match.id, meetingId]
            )
            return true
        }
        if assigned {
            Log.info("Auto-rule: meeting \(meetingId) («\(title)») → series «\(match.name)»")
            return match
        }
        return nil
    }

    /// Series-less meetings whose title the series' rule matches: what a
    /// retroactive apply would take — shown before it runs.
    func retroMatches(_ series: MeetingSeries) async throws -> [String] {
        guard let pattern = series.autoRulePattern,
              SeriesAutoRule.isValidPattern(pattern) else { return [] }
        let candidates: [(String, String)] = try await db.reader.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, title FROM meetings WHERE seriesId IS NULL"
            )
            return rows.map { ($0["id"], $0["title"]) }
        }
        return candidates.filter {
            SeriesAutoRule.matchingSeries(title: $0.1, in: [series])?.id == series.id
        }.map(\.0)
    }

    /// Every series-less meeting goes to the first series whose rule matches its
    /// title — what a new meeting gets (`applyAutoRule`), run over the archive
    /// (AC5). Meetings already in a series are left alone. Per series,
    /// in name order; `dryRun` only counts.
    func applyAllRules(dryRun: Bool) async throws -> [(series: MeetingSeries, count: Int)] {
        let allSeries = try await all()
        let candidates: [(String, String)] = try await db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT id, title FROM meetings WHERE seriesId IS NULL")
                .map { ($0["id"], $0["title"]) }
        }
        var bySeries: [String: [String]] = [:]
        for (id, title) in candidates {
            if let match = SeriesAutoRule.matchingSeries(title: title, in: allSeries) {
                bySeries[match.id, default: []].append(id)
            }
        }
        let planned = allSeries.compactMap { s in bySeries[s.id].map { (series: s, ids: $0) } }
        guard !dryRun else { return planned.map { ($0.series, $0.ids.count) } }
        return try await db.writer.write { db in
            try planned.map { item in
                var changed = 0
                for id in item.ids {
                    try db.execute(
                        sql: "UPDATE meetings SET seriesId = ? WHERE id = ? AND seriesId IS NULL",
                        arguments: [item.series.id, id]
                    )
                    changed += db.changesCount
                }
                return (item.series, changed)
            }
        }
    }

    /// Retroactively apply one series' rule to all series-less meetings.
    /// Returns the number of meetings actually assigned.
    func applyRuleRetroactively(_ series: MeetingSeries) async throws -> Int {
        let matching = try await retroMatches(series)
        guard !matching.isEmpty else { return 0 }
        let assigned = try await db.writer.write { db in
            var changed = 0
            for id in matching {
                try db.execute(
                    sql: "UPDATE meetings SET seriesId = ? WHERE id = ? AND seriesId IS NULL",
                    arguments: [series.id, id]
                )
                changed += db.changesCount
            }
            return changed
        }
        Log.info("Auto-rule retro: \(assigned) meetings → series «\(series.name)»")
        return assigned
    }
}

struct SeriesInfo: Sendable {
    let series: MeetingSeries
    let meetingCount: Int
    let lastMeetingDate: Date?
    let totalDurationSeconds: Double
}
