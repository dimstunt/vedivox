import Testing
import Foundation
@testable import VedivoxMCPLib

/// Pins the EXACT text every tool returns on success (scriptable-cli, group 1).
///
/// The operations/presentation split must not change what the MCP client sees.
/// `contains`-style checks let a formatting regression slip; these compare the
/// whole string. Date fragments are rendered through the same DateFormatter
/// pattern the tools use, so the tests hold in any timezone.
@Suite("Verbatim tool output", .serialized)
struct VerbatimOutputTests {

    private func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func minute(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    // MARK: - Read tools

    @Test("list_meetings success line, verbatim")
    func listMeetings() throws {
        let db = try makeTestDB()
        let start = Date(timeIntervalSince1970: 1_756_600_000)
        let seriesId = try insertSeries(db: db, name: "Weekly")
        let meetingId = try insertMeeting(
            db: db, id: "M1", title: "Планёрка", startTime: start,
            durationSeconds: 3600, status: "done", seriesId: seriesId
        )
        let alice = try insertSpeaker(db: db, name: "Alice")
        try insertMeetingSpeaker(db: db, meetingId: meetingId, speakerId: alice)
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: alice)

        let result = try ListMeetingsTool.run(params: [:], db: db)
        #expect(result == "1. [M1] Планёрка (\(day(start)), 1h) vedivox://meeting/M1 [Weekly] — Speakers: Alice")
    }

    @Test("get_meeting success block, verbatim")
    func getMeeting() throws {
        let db = try makeTestDB()
        let start = Date(timeIntervalSince1970: 1_756_600_000)
        let meetingId = try insertMeeting(
            db: db, id: "M1", title: "Планёрка", startTime: start,
            durationSeconds: 90, status: "done", description: "Обсудили релиз"
        )
        let me = try insertSpeaker(db: db, name: "Alex", isMe: true)
        try insertMeetingSpeaker(db: db, meetingId: meetingId, speakerId: me)
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: me)

        let result = try GetMeetingTool.run(params: ["meeting_id": .string("M1")], db: db)
        #expect(result == """
            ID: M1
            Title: Планёрка
            Date: \(minute(start))
            Duration: 1m 30s
            Status: done
            URL: vedivox://meeting/M1
            Description: Обсудили релиз
            Speakers: Alex (★)
            """)
    }

    @Test("get_transcript success output, verbatim")
    func getTranscript() throws {
        let db = try makeTestDB()
        let start = Date(timeIntervalSince1970: 1_756_600_000)
        let meetingId = try insertMeeting(
            db: db, id: "M1", title: "Планёрка", startTime: start, durationSeconds: 60
        )
        let alice = try insertSpeaker(db: db, name: "Alice")
        _ = try insertSegment(
            db: db, meetingId: meetingId, speakerId: alice, speakerLabel: "Alice",
            startTime: 0, endTime: 5, text: "Привет."
        )
        _ = try insertSegment(
            db: db, meetingId: meetingId, speakerId: alice, speakerLabel: "Alice",
            startTime: 6, endTime: 10, text: "Начнём."
        )

        let result = try GetTranscriptTool.run(params: ["meeting_id": .string("M1")], db: db)
        #expect(result == """
            Meeting: Планёрка
            Date: \(minute(start))
            Duration: 1m
            URL: vedivox://meeting/M1

            [00:00:00 → 00:00:10] Alice: Привет. Начнём.
            """)
    }

    @Test("list_speakers success lines, verbatim")
    func listSpeakers() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, id: "M1")
        let owner = try insertSpeaker(db: db, id: "S1", name: "Alex", isMe: true)
        _ = try insertSpeaker(db: db, id: "S2", name: "Alice", nickname: "ali", nameRu: "Алиса")
        try insertMeetingSpeaker(db: db, meetingId: meetingId, speakerId: owner)

        let result = try ListSpeakersTool.run(params: [:], db: db)
        #expect(result == """
            1. [S1] Alex (★) — 1 meeting
            2. [S2] Алиса (nickname: ali, ru: Алиса, en: Alice) — 0 meetings
            """)
    }

    @Test("search_transcripts success line, verbatim")
    func searchTranscripts() throws {
        let db = try makeTestDB()
        let start = Date(timeIntervalSince1970: 1_756_600_000)
        let meetingId = try insertMeeting(db: db, id: "M1", title: "Планёрка", startTime: start)
        let alice = try insertSpeaker(db: db, name: "Alice")
        _ = try insertSegment(
            db: db, meetingId: meetingId, speakerId: alice, speakerLabel: "Alice",
            startTime: 65, endTime: 70, text: "Обсудим бюджет завтра"
        )
        try syncFTS(db: db)

        let result = try SearchTranscriptsTool.run(params: ["query": .string("бюджет")], db: db)
        #expect(result == "[Планёрка, \(day(start)) 00:01:05] Alice: Обсудим бюджет завтра")
    }

    @Test("list_series success output, verbatim")
    func listSeries() throws {
        let db = try makeTestDB()
        let seriesId = try insertSeries(db: db, name: "Weekly")
        _ = try insertMeeting(db: db, id: "M1", seriesId: seriesId)

        let result = try ListSeriesTool.run(params: [:], db: db)
        #expect(result == """
            Found 1 series:
            - Weekly (id: \(seriesId), meetings: 1)
            """)
    }

    @Test("list_marks success lines, verbatim")
    func listMarks() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, id: "M1")
        _ = try insertMark(db: db, meetingId: meetingId, startTime: 10, endTime: 25)
        _ = try insertMark(db: db, meetingId: meetingId, startTime: 40, endTime: nil, track: "system")
        // Shorter than a second: whole-second output showed it as 00:00:00 → 00:00:00.
        _ = try insertMark(db: db, meetingId: meetingId, startTime: 0.16, endTime: 0.48)

        let result = try ListMarksTool.run(params: ["meeting_id": .string("M1")], db: db)
        #expect(result == """
            #3 [00:00:00.2 → 00:00:00.5] track=mic excluded (manual)
            #1 [00:00:10.0 → 00:00:25.0] track=mic excluded (manual)
            #2 [00:00:40.0 → open] track=system excluded (manual)
            """)
    }

    // MARK: - Socket tools: on success the app's own message passes through untouched

    private func okPassesThrough(
        _ run: (_ params: [String: AnyCodable]) throws -> String,
        params: [String: AnyCodable]
    ) throws {
        let answer: @Sendable (AppCommandRequest) throws -> AppCommandResponse = { _ in
            AppCommandResponse(ok: true, message: "Сделано в приложении", reason: nil)
        }
        let result = try withStubbedApp(answering: answer) {
            try run(params)
        }
        #expect(result == "Сделано в приложении")
    }

    @Test("update_meeting relays the app's success message verbatim")
    func updateMeeting() throws {
        try okPassesThrough(
            UpdateMeetingTool.run,
            params: ["meeting_id": .string("M1"), "title": .string("T")]
        )
    }

    @Test("update_speaker relays the app's success message verbatim")
    func updateSpeaker() throws {
        try okPassesThrough(
            UpdateSpeakerTool.run,
            params: ["speaker_id": .string("S1"), "name": .string("Глеб")]
        )
    }

    @Test("update_segment relays the app's success message verbatim")
    func updateSegment() throws {
        try okPassesThrough(
            UpdateSegmentTool.run,
            params: ["segment_id": AnyCodable(7), "speaker_id": .string("S1")]
        )
    }

    @Test("merge_speakers relays the app's success message verbatim")
    func mergeSpeakers() throws {
        try okPassesThrough(
            MergeSpeakersTool.run,
            params: ["target_id": .string("T"), "source_ids": .array([.string("A")])]
        )
    }

    @Test("create_series relays the app's success message verbatim")
    func createSeries() throws {
        try okPassesThrough(
            CreateSeriesTool.run,
            params: ["name": .string("Weekly")]
        )
    }

    @Test("mark_excluded relays the app's success message verbatim")
    func markExcluded() throws {
        try okPassesThrough(
            MarkExcludedTool.run,
            params: ["meeting_id": .string("M1"), "from": AnyCodable(1.0), "to": AnyCodable(2.0)]
        )
    }

    @Test("unmark relays the app's success message verbatim")
    func unmark() throws {
        try okPassesThrough(
            UnmarkTool.run,
            params: ["meeting_id": .string("M1"), "mark_id": AnyCodable(3)]
        )
    }
}
