import Testing
import Foundation
@testable import VedivoxMCPLib

@Suite("DatabaseReader")
struct DatabaseReaderTests {

    // MARK: - listMeetings

    @Test("lists meetings sorted newest first by default")
    func testListMeetingsDefault() throws {
        let db = try makeTestDB()
        let id1 = try insertMeeting(db: db, title: "Old", startTime: Date(timeIntervalSince1970: 1000), status: "done")
        let id2 = try insertMeeting(db: db, title: "New", startTime: Date(timeIntervalSince1970: 2000), status: "done")

        let meetings = try db.listMeetings(speaker: nil, dateFrom: nil, dateTo: nil, series: nil, limit: 10, sort: "newest")
        #expect(meetings.count == 2)
        #expect(meetings[0].id == id2)
        #expect(meetings[1].id == id1)
    }

    @Test("lists meetings sorted oldest first")
    func testListMeetingsOldest() throws {
        let db = try makeTestDB()
        let id1 = try insertMeeting(db: db, title: "Old", startTime: Date(timeIntervalSince1970: 1000), status: "done")
        _ = try insertMeeting(db: db, title: "New", startTime: Date(timeIntervalSince1970: 2000), status: "done")

        let meetings = try db.listMeetings(speaker: nil, dateFrom: nil, dateTo: nil, series: nil, limit: 10, sort: "oldest")
        #expect(meetings[0].id == id1)
    }

    @Test("filters by several speaker IDs — all must be present")
    func testListMeetingsBySpeakerIdsRequiresAll() throws {
        let db = try makeTestDB()
        let both = try insertMeeting(db: db, title: "Alice and Bob", status: "done")
        let aliceOnly = try insertMeeting(db: db, title: "Alice only", status: "done")
        let alice = try insertSpeaker(db: db, name: "Alice")
        let bob = try insertSpeaker(db: db, name: "Bob")
        try insertMeetingSpeaker(db: db, meetingId: both, speakerId: alice)
        try insertMeetingSpeaker(db: db, meetingId: both, speakerId: bob)
        try insertMeetingSpeaker(db: db, meetingId: aliceOnly, speakerId: alice)

        let shared = try db.listMeetings(speaker: nil, speakerIds: [alice, bob], dateFrom: nil, dateTo: nil, series: nil, limit: 10, sort: "newest")
        #expect(shared.map(\.id) == [both])

        let anyAlice = try db.listMeetings(speaker: nil, speakerIds: [alice], dateFrom: nil, dateTo: nil, series: nil, limit: 10, sort: "newest")
        #expect(Set(anyAlice.map(\.id)) == [both, aliceOnly])
    }

    @Test("excludes non-done meetings")
    func testListMeetingsExcludesNonDone() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, title: "Recording", status: "recording")
        _ = try insertMeeting(db: db, title: "Done", status: "done")

        let meetings = try db.listMeetings(speaker: nil, dateFrom: nil, dateTo: nil, series: nil, limit: 10, sort: "newest")
        #expect(meetings.count == 1)
        #expect(meetings[0].title == "Done")
    }

    @Test("filters by speaker name")
    func testListMeetingsFilterBySpeaker() throws {
        let db = try makeTestDB()
        let m1 = try insertMeeting(db: db, title: "With Alice", status: "done")
        let m2 = try insertMeeting(db: db, title: "Without Alice", status: "done")
        let alice = try insertSpeaker(db: db, name: "Alice")
        let bob = try insertSpeaker(db: db, name: "Bob")
        try insertMeetingSpeaker(db: db, meetingId: m1, speakerId: alice)
        try insertMeetingSpeaker(db: db, meetingId: m2, speakerId: bob)

        let meetings = try db.listMeetings(speaker: "Alice", dateFrom: nil, dateTo: nil, series: nil, limit: 10, sort: "newest")
        #expect(meetings.count == 1)
        #expect(meetings[0].id == m1)
    }

    @Test("filters by date range")
    func testListMeetingsFilterByDate() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, title: "Jan", startTime: Date(timeIntervalSince1970: 1704067200), status: "done") // 2024-01-01
        let feb = try insertMeeting(db: db, title: "Feb", startTime: Date(timeIntervalSince1970: 1706745600), status: "done") // 2024-02-01

        let meetings = try db.listMeetings(speaker: nil, dateFrom: "2024-01-15", dateTo: "2024-02-15", series: nil, limit: 10, sort: "newest")
        #expect(meetings.count == 1)
        #expect(meetings[0].id == feb)
    }

    /// 20:00 in New York on 9 November is already 10 November in UTC, which
    /// is how the column stores it. Asked for the 9th, the list missed it.
    @Test("a date filter means the caller's local day")
    func testListMeetingsDateIsLocalDay() throws {
        let db = try makeTestDB()
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let evening = try #require(ISO8601DateFormatter().date(from: "2026-11-10T01:00:00Z"))
        let id = try insertMeeting(db: db, title: "Evening call", startTime: evening, status: "done")

        func ids(_ from: String, _ to: String) throws -> [String] {
            try db.listMeetings(
                speaker: nil, dateFrom: from, dateTo: to, series: nil, limit: 10, sort: "newest", timeZone: newYork
            ).map(\.id)
        }
        #expect(try ids("2026-11-09", "2026-11-09") == [id])
        #expect(try ids("2026-11-10", "2026-11-10").isEmpty)
        #expect(try ids("2026-11-08", "2026-11-08").isEmpty)
    }

    @Test("a date in another format is refused, not compared as text")
    func testListMeetingsRejectsOtherDateFormats() throws {
        let db = try makeTestDB()
        #expect(throws: MCPError.self) {
            _ = try db.listMeetings(speaker: nil, dateFrom: "09.11.2026", dateTo: nil, series: nil, limit: 10, sort: "newest")
        }
        #expect(throws: MCPError.self) {
            _ = try db.listMeetings(speaker: nil, dateFrom: nil, dateTo: "yesterday", series: nil, limit: 10, sort: "newest")
        }
    }

    @Test("filters by series name")
    func testListMeetingsFilterBySeries() throws {
        let db = try makeTestDB()
        let seriesId = try insertSeries(db: db, name: "Daily Standup")
        let m1 = try insertMeeting(db: db, title: "Standup #1", status: "done", seriesId: seriesId)
        _ = try insertMeeting(db: db, title: "Random", status: "done")

        let meetings = try db.listMeetings(speaker: nil, dateFrom: nil, dateTo: nil, series: "Standup", limit: 10, sort: "newest")
        #expect(meetings.count == 1)
        #expect(meetings[0].id == m1)
    }

    @Test("respects limit")
    func testListMeetingsLimit() throws {
        let db = try makeTestDB()
        for i in 0 ..< 5 {
            _ = try insertMeeting(db: db, title: "Meeting \(i)", startTime: Date(timeIntervalSince1970: Double(i * 1000)), status: "done")
        }

        let meetings = try db.listMeetings(speaker: nil, dateFrom: nil, dateTo: nil, series: nil, limit: 3, sort: "newest")
        #expect(meetings.count == 3)
    }

    // MARK: - getMeeting

    @Test("returns meeting by ID")
    func testGetMeeting() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, title: "Target Meeting", status: "done")

        let meeting = try db.getMeeting(meetingId: id)
        #expect(meeting.title == "Target Meeting")
    }

    @Test("throws meetingNotFound for unknown ID")
    func testGetMeetingNotFound() throws {
        let db = try makeTestDB()

        #expect(throws: MCPError.self) {
            _ = try db.getMeeting(meetingId: "nonexistent")
        }
    }

    // MARK: - getTranscript

    @Test("returns meeting with transcript segments")
    func testGetTranscript() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "Transcribed", status: "done")
        let speakerId = try insertSpeaker(db: db, name: "Alice")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 0, endTime: 5, text: "Hello")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 5, endTime: 10, text: "World")

        let (meeting, segments) = try db.getTranscript(meetingId: meetingId)
        #expect(meeting.title == "Transcribed")
        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello")
        #expect(segments[1].text == "World")
    }

    @Test("getTranscript throws for unknown meeting")
    func testGetTranscriptNotFound() throws {
        let db = try makeTestDB()

        #expect(throws: MCPError.self) {
            _ = try db.getTranscript(meetingId: "nonexistent")
        }
    }

    // MARK: - searchTranscripts

    @Test("FTS5 search finds matching segments")
    func testSearchTranscripts() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "Search Test", status: "done")
        _ = try insertSegment(db: db, meetingId: meetingId, text: "The quick brown fox jumps")
        _ = try insertSegment(db: db, meetingId: meetingId, text: "Something completely different")
        try syncFTS(db: db)

        let results = try db.searchTranscripts(query: "quick brown", limit: 10)
        #expect(results.count == 1)
        #expect(results[0].segment.text == "The quick brown fox jumps")
        #expect(results[0].meetingTitle == "Search Test")
    }

    /// `vedivox search` and search_transcripts return lines, so every word must be
    /// in one line; the sidebar's meeting-level search is different
    /// on purpose. Pins the contract the help text describes.
    @Test("search matches word prefixes within one line, never across lines or in the title")
    func testSearchIsPerLine() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(
            db: db, title: "Budget review", status: "done", description: "quarterly planning"
        )
        _ = try insertSegment(db: db, meetingId: meetingId, text: "the dataset is ready")
        _ = try insertSegment(db: db, meetingId: meetingId, startTime: 10, endTime: 15, text: "medians look fine")
        try syncFTS(db: db)

        #expect(try db.searchTranscripts(query: "data ready", limit: 10).map(\.segment.text) == ["the dataset is ready"])
        #expect(try db.searchTranscripts(query: "dataset medians", limit: 10).isEmpty, "words in different lines")
        #expect(try db.searchTranscripts(query: "budget", limit: 10).isEmpty, "title is not searched")
        #expect(try db.searchTranscripts(query: "quarterly", limit: 10).isEmpty, "description is not searched")
    }

    /// the meeting-level mode is the sidebar's rule — words may sit in
    /// different lines, in the title or in the description; excluded lines do not count.
    @Test("searchMeetings matches words anywhere in the meeting, newest first")
    func testSearchMeetings() throws {
        let db = try makeTestDB()
        let older = try insertMeeting(
            db: db, title: "Budget review", startTime: Date(timeIntervalSince1970: 1_000),
            status: "done", description: "quarterly planning"
        )
        _ = try insertSegment(db: db, meetingId: older, text: "the dataset is ready")
        _ = try insertSegment(db: db, meetingId: older, startTime: 10, endTime: 15, text: "medians look fine")
        _ = try insertSegment(db: db, meetingId: older, startTime: 20, endTime: 25, text: "secret", isExcluded: true)
        let newer = try insertMeeting(db: db, title: "Dataset sync", startTime: Date(timeIntervalSince1970: 2_000))
        try syncFTS(db: db)

        #expect(try db.searchMeetings(query: "dataset medians", limit: 10).map(\.id) == [older], "different lines")
        #expect(try db.searchMeetings(query: "budget data", limit: 10).map(\.id) == [older], "title + line prefix")
        #expect(try db.searchMeetings(query: "quarterly", limit: 10).map(\.id) == [older], "description")
        #expect(try db.searchMeetings(query: "dataset", limit: 10).map(\.id) == [newer, older], "newest first")
        #expect(try db.searchMeetings(query: "dataset", limit: 1).map(\.id) == [newer])
        #expect(try db.searchMeetings(query: "secret", limit: 10).isEmpty, "excluded line")
        #expect(try db.searchMeetings(query: "secret", limit: 10, includeExcluded: true).map(\.id) == [older])
        #expect(try db.searchMeetings(query: "budget nothinglikethis", limit: 10).isEmpty)
    }

    @Test("FTS5 search returns empty for no match")
    func testSearchTranscriptsNoMatch() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "Empty", status: "done")
        _ = try insertSegment(db: db, meetingId: meetingId, text: "Hello world")
        try syncFTS(db: db)

        let results = try db.searchTranscripts(query: "xyznonexistent", limit: 10)
        #expect(results.isEmpty)
    }

    // MARK: - listSpeakers

    @Test("lists all speakers with meeting counts")
    func testListSpeakersAll() throws {
        let db = try makeTestDB()
        let m1 = try insertMeeting(db: db, title: "M1", status: "done")
        let m2 = try insertMeeting(db: db, title: "M2", status: "done")
        let alice = try insertSpeaker(db: db, name: "Alice")
        let bob = try insertSpeaker(db: db, name: "Bob")
        try insertMeetingSpeaker(db: db, meetingId: m1, speakerId: alice)
        try insertMeetingSpeaker(db: db, meetingId: m2, speakerId: alice)
        try insertMeetingSpeaker(db: db, meetingId: m1, speakerId: bob)

        let speakers = try db.listSpeakers(meetingId: nil)
        #expect(speakers.count == 2)
        // Sorted by meetingCount DESC — Alice has 2, Bob has 1
        #expect(speakers[0].speaker.nameEn == "Alice")
        #expect(speakers[0].meetingCount == 2)
        #expect(speakers[1].speaker.nameEn == "Bob")
        #expect(speakers[1].meetingCount == 1)
    }

    @Test("lists speakers filtered by meeting")
    func testListSpeakersByMeeting() throws {
        let db = try makeTestDB()
        let m1 = try insertMeeting(db: db, title: "M1", status: "done")
        let m2 = try insertMeeting(db: db, title: "M2", status: "done")
        let alice = try insertSpeaker(db: db, name: "Alice")
        let bob = try insertSpeaker(db: db, name: "Bob")
        try insertMeetingSpeaker(db: db, meetingId: m1, speakerId: alice)
        try insertMeetingSpeaker(db: db, meetingId: m2, speakerId: bob)

        let speakers = try db.listSpeakers(meetingId: m1)
        #expect(speakers.count == 1)
        #expect(speakers[0].speaker.nameEn == "Alice")
    }

    @Test("global listing hides unconfirmed auto-labels")
    func testListSpeakersHidesAutoLabels() throws {
        let db = try makeTestDB()
        let m1 = try insertMeeting(db: db, title: "M1", status: "done")
        let alice = try insertSpeaker(db: db, name: "Alice")
        let phantom = try insertSpeaker(db: db, name: "speaker_1")
        let oddHuman = try insertSpeaker(db: db, name: "speaker_1a")
        try insertMeetingSpeaker(db: db, meetingId: m1, speakerId: alice)
        try insertMeetingSpeaker(db: db, meetingId: m1, speakerId: phantom)
        try insertMeetingSpeaker(db: db, meetingId: m1, speakerId: oddHuman)

        // Автозаписи — слоты встречи, не персоны (speaker-row-per-mint):
        // глобальный список их прячет, список встречи — показывает. Форма
        // строгая: «speaker_1a» — человеческое имя, не прячется.
        let global = try db.listSpeakers(meetingId: nil)
        #expect(Set(global.map(\.speaker.nameEn)) == ["Alice", "speaker_1a"])

        let inMeeting = try db.listSpeakers(meetingId: m1)
        #expect(Set(inMeeting.map(\.speaker.nameEn)) == ["Alice", "speaker_1", "speaker_1a"])
    }

    // Tests for updateMeeting, updateSpeaker and mergeSpeakers used to live
    // here. Those operations are no longer performed by this class: the app is
    // the only writer, and the tools send it commands. Their behaviour is
    // covered where it now lives — the app's command executor — and the tool
    // side is covered in ToolTests.

    // MARK: - speakerNames

    @Test("returns speaker names with star for isMe")
    func testSpeakerNames() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "M", status: "done")
        let me = try insertSpeaker(db: db, name: "Me", isMe: true)
        let other = try insertSpeaker(db: db, name: "Other")
        try insertMeetingSpeaker(db: db, meetingId: meetingId, speakerId: me)
        try insertMeetingSpeaker(db: db, meetingId: meetingId, speakerId: other)

        let names = try db.speakerNames(forMeeting: meetingId)
        // isMe speakers sorted first
        #expect(names[0] == "Me (\u{2605})")
        #expect(names[1] == "Other")
    }

    // MARK: - seriesName

    @Test("returns series name by ID")
    func testSeriesName() throws {
        let db = try makeTestDB()
        let seriesId = try insertSeries(db: db, name: "Daily")

        let name = try db.seriesName(forId: seriesId)
        #expect(name == "Daily")
    }

    @Test("returns nil for nil series ID")
    func testSeriesNameNil() throws {
        let db = try makeTestDB()

        let name = try db.seriesName(forId: nil)
        #expect(name == nil)
    }
}

@Suite("Exclusion marks")
struct ExclusionReadTests {

    @Test("get_transcript hides excluded segments by default and returns them on request")
    func testGetTranscriptExclusionFilter() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db)
        _ = try insertSegment(db: db, meetingId: meetingId, startTime: 0, endTime: 5, text: "visible")
        _ = try insertSegment(db: db, meetingId: meetingId, startTime: 5, endTime: 10, text: "hidden", isExcluded: true)

        let (_, defaults) = try db.getTranscript(meetingId: meetingId)
        #expect(defaults.map(\.text) == ["visible"])

        let (_, all) = try db.getTranscript(meetingId: meetingId, includeExcluded: true)
        #expect(all.map(\.text) == ["visible", "hidden"])
        #expect(all.last?.isExcluded == true)
    }

    @Test("search skips excluded segments unless asked")
    func testSearchExclusionFilter() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db)
        _ = try insertSegment(db: db, meetingId: meetingId, text: "секретный разговор", isExcluded: true)
        _ = try insertSegment(db: db, meetingId: meetingId, text: "обычный разговор")
        try syncFTS(db: db)

        let defaults = try db.searchTranscripts(query: "разговор", limit: 10)
        #expect(defaults.count == 1)
        #expect(defaults.first?.segment.text == "обычный разговор")

        let all = try db.searchTranscripts(query: "разговор", limit: 10, includeExcluded: true)
        #expect(all.count == 2)
    }

    @Test("listMarks returns marks in start order and fails for unknown meeting")
    func testListMarks() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db)
        _ = try insertMark(db: db, meetingId: meetingId, startTime: 30, endTime: nil, source: "button")
        _ = try insertMark(db: db, meetingId: meetingId, startTime: 5, endTime: 12)

        let marks = try db.listMarks(meetingId: meetingId)
        #expect(marks.map(\.startTime) == [5, 30])
        #expect(marks.last?.endTime == nil)

        #expect(throws: MCPError.self) {
            _ = try db.listMarks(meetingId: "missing")
        }
    }
}
