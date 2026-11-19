import Testing
import Foundation
import os
@testable import VedivoxMCPLib

/// Thread-safe box for capturing values in @Sendable closures.
final class CapturedURL: Sendable {
    private let storage = OSAllocatedUnfairLock<String?>(initialState: nil)
    var value: String? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// Captures the command a tool sends to the running app.
///
/// Replaces capturing a `vedivox://` string: the tools no longer hand a URL to the
/// system, they send a command and report what came back.
final class CapturedCommand: Sendable {
    private let storage = OSAllocatedUnfairLock<AppCommandRequest?>(initialState: nil)
    var value: AppCommandRequest? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    var params: [String: String] { value?.params ?? [:] }
}

/// `AppCommandDispatch.run` is process-global and Swift Testing runs suites in
/// parallel: without the lock one suite restores the real client while another
/// is still inside its body, and that body's command goes to the user's
/// running Vedivox (same race as `cliRuntimeLock` in CLITests).
private let stubbedAppLock = NSRecursiveLock()

/// Installs a stand-in for the app, restoring the real one when done.
/// `serving: false` is an app that is not running, for the commands that
/// never launch it.
func withStubbedApp<T>(
    serving: Bool = true,
    capturing captured: CapturedCommand? = nil,
    answering answer: @escaping @Sendable (AppCommandRequest) throws -> AppCommandResponse = { request in
        AppCommandResponse(ok: true, message: "Готово: \(request.command)", reason: nil)
    },
    _ body: () throws -> T
) rethrows -> T {
    _ = appIsOffLimits
    stubbedAppLock.lock()
    let saved = AppCommandDispatch.run
    let savedIfServing = AppCommandDispatch.runIfServing
    AppCommandDispatch.run = { request in
        captured?.value = request
        return try answer(request)
    }
    AppCommandDispatch.runIfServing = { request in
        guard serving else { return nil }
        captured?.value = request
        return try answer(request)
    }
    defer {
        AppCommandDispatch.run = saved
        AppCommandDispatch.runIfServing = savedIfServing
        stubbedAppLock.unlock()
    }
    return try body()
}

@Suite("Tool parameter parsing and validation", .serialized)
struct ToolTests {

    // MARK: - ListMeetingsTool

    @Test("list_meetings applies speaker, date range, sort and limit together")
    func testListMeetingsParams() throws {
        let db = try makeTestDB()
        // Noon local time: the date filters name local days.
        func noon(_ day: Int, month: Int = 1) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        }
        let alice = try insertSpeaker(db: db, name: "Alice")
        let bob = try insertSpeaker(db: db, name: "Bob")
        func meeting(_ title: String, _ start: Date, _ speaker: String) throws -> String {
            let id = try insertMeeting(db: db, title: title, startTime: start)
            try insertMeetingSpeaker(db: db, meetingId: id, speakerId: speaker)
            return id
        }
        _ = try meeting("Before range", noon(9), alice)
        let first = try meeting("First in range", noon(10), alice)
        let second = try meeting("Second in range", noon(15), alice)
        let last = try meeting("Last day of range", noon(20), alice)
        _ = try meeting("Bob only", noon(12), bob)
        _ = try meeting("After range", noon(21), alice)

        func titles(sort: String) throws -> [String] {
            let result = try ListMeetingsTool.run(
                params: [
                    "speaker": .string("Ali"),
                    "date_from": .string("2026-01-10"),
                    "date_to": .string("2026-01-20"),
                    "limit": AnyCodable(2),
                    "sort": .string(sort),
                ],
                db: db
            )
            return result.split(separator: "\n").map(String.init)
        }

        let oldest = try titles(sort: "oldest")
        #expect(oldest.count == 2)
        #expect(oldest.first?.hasPrefix("1. [\(first)] First in range") == true)
        #expect(oldest.last?.hasPrefix("2. [\(second)] Second in range") == true)

        // date_to is inclusive of its whole day; limit cuts from the other end.
        let newest = try titles(sort: "newest")
        #expect(newest.count == 2)
        #expect(newest.first?.hasPrefix("1. [\(last)] Last day of range") == true)
        #expect(newest.last?.hasPrefix("2. [\(second)] Second in range") == true)

        let all = (oldest + newest).joined(separator: "\n")
        for excluded in ["Before range", "After range", "Bob only"] {
            #expect(!all.contains(excluded))
        }
    }

    @Test("list_meetings returns 'No meetings found' for empty result")
    func testListMeetingsEmpty() throws {
        let db = try makeTestDB()

        let result = try ListMeetingsTool.run(params: [:], db: db)
        #expect(result == "No meetings found.")
    }

    @Test("list_meetings defaults to done status only")
    func testListMeetingsDefaultStatus() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, title: "Done Meeting", startTime: Date(), status: "done")
        _ = try insertMeeting(db: db, title: "Recording Meeting", startTime: Date(), status: "recording")

        let result = try ListMeetingsTool.run(params: [:], db: db)
        #expect(result.contains("Done Meeting"))
        #expect(!result.contains("Recording Meeting"))
    }

    @Test("list_meetings filters by status string")
    func testListMeetingsStatusString() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, title: "Done Meeting", startTime: Date(), status: "done")
        _ = try insertMeeting(db: db, title: "Recording Meeting", startTime: Date(), status: "recording")

        let params: [String: AnyCodable] = ["status": .string("recording")]
        let result = try ListMeetingsTool.run(params: params, db: db)
        #expect(!result.contains("Done Meeting"))
        #expect(result.contains("Recording Meeting"))
        #expect(result.contains("[recording]"))
    }

    @Test("list_meetings filters by status array")
    func testListMeetingsStatusArray() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, title: "Done Meeting", startTime: Date(), status: "done")
        _ = try insertMeeting(db: db, title: "Recording Meeting", startTime: Date(), status: "recording")
        _ = try insertMeeting(db: db, title: "Transcribing Meeting", startTime: Date(), status: "transcribing")

        let params: [String: AnyCodable] = [
            "status": .array([.string("recording"), .string("transcribing")]),
        ]
        let result = try ListMeetingsTool.run(params: params, db: db)
        #expect(!result.contains("Done Meeting"))
        #expect(result.contains("Recording Meeting"))
        #expect(result.contains("Transcribing Meeting"))
    }

    @Test("list_meetings shows status label only for non-done meetings")
    func testListMeetingsStatusLabel() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, title: "Done Meeting", startTime: Date(), status: "done")

        let result = try ListMeetingsTool.run(params: [:], db: db)
        #expect(result.contains("Done Meeting"))
        #expect(!result.contains("[done]"))
    }

    // MARK: - GetMeetingTool

    @Test("get_meeting returns error for missing meeting_id")
    func testGetMeetingMissingId() throws {
        let db = try makeTestDB()

        let result = try GetMeetingTool.run(params: [:], db: db)
        #expect(result.contains("Error"))
        #expect(result.contains("meeting_id"))
    }

    @Test("get_meeting returns meeting details")
    func testGetMeetingSuccess() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, title: "My Meeting", status: "done", description: "A good meeting")

        let params: [String: AnyCodable] = ["meeting_id": .string(id)]
        let result = try GetMeetingTool.run(params: params, db: db)
        #expect(result.contains("My Meeting"))
        #expect(result.contains("A good meeting"))
    }

    // MARK: - UpdateMeetingTool

    @Test("update_meeting returns error when no fields provided")
    func testUpdateMeetingNoFields() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, title: "M", status: "done")

        let params: [String: AnyCodable] = ["meeting_id": .string(id)]
        let result = try UpdateMeetingTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("at least one field"))
    }

    @Test("update_meeting sends the change to the app and reports its answer")
    func testUpdateMeetingSuccess() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, title: "Old", status: "done")

        let captured = CapturedCommand()
        let result = try withStubbedApp(
            capturing: captured,
            answering: { _ in AppCommandResponse(ok: true, message: "Обновлена встреча \(id): title", reason: nil) }
        ) {
            try UpdateMeetingTool.run(
                params: ["meeting_id": .string(id), "title": .string("New Title")]
            )
        }

        #expect(captured.value?.command == AppCommandName.updateMeeting)
        #expect(captured.params["meeting_id"] == id)
        #expect(captured.params["title"] == "New Title")
        // Absent fields must not be sent: "leave alone" and "clear" are
        // different requests.
        #expect(captured.params["description"] == nil)
        #expect(result.contains("Обновлена встреча"))
    }

    /// A model that sends `"title": null` next to the field it means to change
    /// used to blank the title: null became "", and "" means "clear".
    @Test("update_meeting and update_speaker leave a null or non-string field alone")
    func testUpdateIgnoresNullFields() throws {
        func json(_ text: String) throws -> [String: AnyCodable] {
            try JSONDecoder().decode([String: AnyCodable].self, from: Data(text.utf8))
        }

        let meeting = CapturedCommand()
        _ = try withStubbedApp(capturing: meeting) {
            try UpdateMeetingTool.run(
                params: json(#"{"meeting_id": "M1", "description": "notes", "title": null, "series_id": 7}"#)
            )
        }
        #expect(meeting.params == ["meeting_id": "M1", "description": "notes"])

        let speaker = CapturedCommand()
        _ = try withStubbedApp(capturing: speaker) {
            try UpdateSpeakerTool.run(
                params: json(#"{"speaker_id": "S1", "nickname": "", "name_en": null, "name": 5}"#)
            )
        }
        // An empty string still travels: that is how a nickname is erased.
        #expect(speaker.params == ["speaker_id": "S1", "nickname": ""])

        let nothing = try withStubbedApp {
            try UpdateMeetingTool.run(params: json(#"{"meeting_id": "M1", "title": null}"#))
        }
        #expect(nothing.contains("at least one field"))
    }

    // MARK: - MergeSpeakersTool

    @Test("merge_speakers returns error when target is in sources")
    func testMergeSpeakersTargetInSources() throws {

        let params: [String: AnyCodable] = [
            "target_id": .string("speaker-1"),
            "source_ids": .array([.string("speaker-1"), .string("speaker-2")]),
        ]
        let result = try MergeSpeakersTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("target_id must not be in source_ids"))
    }

    @Test("merge_speakers returns error for empty source_ids")
    func testMergeSpeakersEmptySources() throws {

        let params: [String: AnyCodable] = [
            "target_id": .string("speaker-1"),
            "source_ids": .array([]),
        ]
        let result = try MergeSpeakersTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("must not be empty"))
    }

    @Test("merge_speakers returns error for missing target_id")
    func testMergeSpeakersMissingTarget() throws {

        let result = try MergeSpeakersTool.run(params: [:])
        #expect(result.contains("Error"))
        #expect(result.contains("target_id"))
    }

    // MARK: - ReprocessMeetingTool

    @Test("reprocess_meeting returns error for missing meeting_id")
    func testReprocessMissingId() throws {
        let db = try makeTestDB()

        let result = try ReprocessMeetingTool.run(params: [:], db: db)
        #expect(result.contains("Error"))
        #expect(result.contains("meeting_id"))
    }

    @Test("reprocess_meeting reports what the app did, not that it was asked")
    func testReprocessHappyPath() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, title: "My Meeting", status: "done")

        let captured = CapturedCommand()
        let result = try withStubbedApp(
            capturing: captured,
            answering: { _ in AppCommandResponse(ok: true, message: "Переобработка «My Meeting» завершена", reason: nil) }
        ) {
            try ReprocessMeetingTool.run(params: ["meeting_id": .string(id)], db: db)
        }

        #expect(captured.value?.command == AppCommandName.reprocessMeeting)
        #expect(captured.params["meeting_id"] == id)
        // Absent means autodetect, which is not the same as false.
        #expect(captured.params["suppress_echo"] == nil)
        #expect(result == "Переобработка «My Meeting» завершена")
    }

    @Test("reprocess_meeting surfaces a refusal instead of reporting success")
    func testReprocessRefusalIsReported() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, title: "My Meeting", status: "done")

        let result = try withStubbedApp(
            answering: { _ in
                AppCommandResponse(ok: false, message: "Аудио не найдено", reason: "missing_audio")
            }
        ) {
            try ReprocessMeetingTool.run(params: ["meeting_id": .string(id)], db: db)
        }

        #expect(result.contains("Error"))
        #expect(result.contains("Аудио не найдено"))
        #expect(result.contains("missing_audio"))
    }

    @Test("reprocess_meeting reports an unreachable app as failure")
    func testReprocessUnreachableAppIsReported() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, title: "My Meeting", status: "done")

        let result = try withStubbedApp(
            answering: { _ in throw AppCommandError.notReachable("connect refused") }
        ) {
            try ReprocessMeetingTool.run(params: ["meeting_id": .string(id)], db: db)
        }

        #expect(result.contains("Error"))
        #expect(result.contains("Vedivox is not answering"))
    }

    @Test("reprocess_meeting carries an explicit echo choice")
    func testReprocessCarriesEchoChoice() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, title: "My Meeting", status: "done")

        let captured = CapturedCommand()
        _ = try withStubbedApp(capturing: captured) {
            try ReprocessMeetingTool.run(
                params: ["meeting_id": .string(id), "suppress_echo": .bool(true)],
                db: db
            )
        }
        #expect(captured.params["suppress_echo"] == "1")
    }

    // MARK: - SearchTranscriptsTool

    @Test("search_transcripts returns error for missing query")
    func testSearchMissingQuery() throws {
        let db = try makeTestDB()

        let result = try SearchTranscriptsTool.run(params: [:], db: db)
        #expect(result.contains("Error"))
    }

    // MARK: - GetTranscriptTool

    // MARK: - UpdateSegmentTool

    @Test("update_segment returns error for missing segment_id")
    func testUpdateSegmentMissingId() throws {

        let params: [String: AnyCodable] = ["speaker_id": .string("s1")]
        let result = try UpdateSegmentTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("segment_id"))
    }

    @Test("update_segment returns error for missing speaker_id")
    func testUpdateSegmentMissingSpeaker() throws {

        let params: [String: AnyCodable] = ["segment_id": .int(1)]
        let result = try UpdateSegmentTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("speaker_id"))
    }

    /// The tool does not check speakers itself — the app is the only one that
    /// knows them — so an unknown speaker goes to the app as given, and the
    /// app's refusal comes back as an error with its reason.
    @Test("update_segment forwards an unknown speaker and reports the app's refusal")
    func testUpdateSegmentBadSpeaker() throws {

        let captured = CapturedCommand()
        let result = try withStubbedApp(
            capturing: captured,
            answering: { request in
                AppCommandResponse(
                    ok: false, message: "Спикер \(request.params["speaker_id"] ?? "?") не найден", reason: "not_found"
                )
            }
        ) {
            try UpdateSegmentTool.run(
                params: ["segment_id": .int(1), "speaker_id": .string("nonexistent")]
            )
        }

        #expect(captured.value?.command == AppCommandName.updateSegment)
        #expect(captured.params == ["segment_id": "1", "speaker_id": "nonexistent"])
        #expect(result == "Error: Спикер nonexistent не найден [not_found]")
    }

    /// A segment id that is not a whole number is refused before anything is
    /// sent; a whole one the app does not know is the app's refusal.
    @Test("update_segment refuses a fractional segment id locally and reports an unknown one from the app")
    func testUpdateSegmentBadSegment() throws {

        let captured = CapturedCommand()
        let local = try withStubbedApp(capturing: captured) {
            try UpdateSegmentTool.run(params: ["segment_id": AnyCodable(1.5), "speaker_id": .string("someone")])
        }
        #expect(local == "Error: segment_id is required (integer)")
        #expect(captured.value == nil)

        // JSON numbers may arrive as Double: a whole one is sent as an integer.
        let remote = try withStubbedApp(
            capturing: captured,
            answering: { request in
                AppCommandResponse(ok: false, message: "Сегмент \(request.params["segment_id"] ?? "?") не найден", reason: nil)
            }
        ) {
            try UpdateSegmentTool.run(params: ["segment_id": AnyCodable(9999.0), "speaker_id": .string("someone")])
        }
        #expect(captured.params == ["segment_id": "9999", "speaker_id": "someone"])
        #expect(remote == "Error: Сегмент 9999 не найден")
    }

    @Test("update_segment sends the change to the app")
    func testUpdateSegmentSuccess() throws {

        let captured = CapturedCommand()
        let result = try withStubbedApp(
            capturing: captured,
            answering: { _ in AppCommandResponse(ok: true, message: "Сегмент 42 → «Bob»", reason: nil) }
        ) {
            try UpdateSegmentTool.run(
                params: ["segment_id": .int(42), "speaker_id": .string("bob-id")]
            )
        }

        #expect(captured.value?.command == AppCommandName.updateSegment)
        #expect(captured.params["segment_id"] == "42")
        #expect(captured.params["speaker_id"] == "bob-id")
        #expect(result.contains("Bob"))
    }

    @Test("update_segment works with integer segment_id from JSON")
    func testUpdateSegmentIntegerId() throws {

        let captured = CapturedCommand()
        _ = try withStubbedApp(capturing: captured) {
            try UpdateSegmentTool.run(
                params: ["segment_id": .int(7), "speaker_id": .string("alice-id")]
            )
        }
        #expect(captured.params["segment_id"] == "7")
    }

    @Test("numbers and arrays decoded from real JSON reach the tools")
    func testJSONDecodedNumbersAndArrays() throws {
        func args(_ json: String) throws -> [String: AnyCodable] {
            try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
        }
        let captured = CapturedCommand()
        try withStubbedApp(capturing: captured) {
            _ = try UpdateSegmentTool.run(params: args(#"{"segment_id": 42, "speaker_id": "s"}"#))
            #expect(captured.params["segment_id"] == "42")
            _ = try UnmarkTool.run(params: args(#"{"meeting_id": "m", "mark_id": 7}"#))
            #expect(captured.params["mark_id"] == "7")
            _ = try MergeSpeakersTool.run(params: args(#"{"target_id": "t", "source_ids": ["a", "b"]}"#))
            #expect(captured.params["source_ids"] == "a,b")
        }
    }

    // MARK: - Data Changes Travel As Commands

    @Test("update_speaker sends only the fields it was given")
    func testUpdateSpeakerSendsPresentFieldsOnly() throws {

        let captured = CapturedCommand()
        _ = try withStubbedApp(capturing: captured) {
            try UpdateSpeakerTool.run(
                params: [
                    "speaker_id": .string("s1"),
                    "name": .string("Глеб"),
                    "nickname": .string(""),
                ]
            )
        }

        #expect(captured.value?.command == AppCommandName.updateSpeaker)
        #expect(captured.params["speaker_id"] == "s1")
        #expect(captured.params["name"] == "Глеб")
        // Present but empty means "clear", and must survive as such.
        #expect(captured.params["nickname"] == "")
        #expect(captured.params["name_ru"] == nil)
    }

    @Test("merge_speakers sends the sources as one list")
    func testMergeSpeakersSendsSources() throws {

        let captured = CapturedCommand()
        _ = try withStubbedApp(capturing: captured) {
            try MergeSpeakersTool.run(
                params: [
                    "target_id": .string("target"),
                    "source_ids": .array([.string("a"), .string("b")]),
                ]
            )
        }

        #expect(captured.value?.command == AppCommandName.mergeSpeakers)
        #expect(captured.params["target_id"] == "target")
        #expect(captured.params["source_ids"] == "a,b")
    }

    @Test("create_series sends the name and reports the app's answer")
    func testCreateSeriesSendsName() throws {

        let captured = CapturedCommand()
        let result = try withStubbedApp(
            capturing: captured,
            answering: { _ in AppCommandResponse(ok: true, message: "Создана серия «Планёрка» (id: abc)", reason: nil) }
        ) {
            try CreateSeriesTool.run(params: ["name": .string("Планёрка")])
        }

        #expect(captured.value?.command == AppCommandName.createSeries)
        #expect(captured.params["name"] == "Планёрка")
        #expect(result.contains("id: abc"))
    }

    @Test("a data change that fails is reported as a failure")
    func testDataChangeFailureIsReported() throws {

        let result = try withStubbedApp(
            answering: { _ in
                AppCommandResponse(ok: false, message: "Не удалось обновить спикера", reason: "failed")
            }
        ) {
            try UpdateSpeakerTool.run(
                params: ["speaker_id": .string("s1"), "name": .string("X")]
            )
        }

        #expect(result.contains("Error"))
        #expect(result.contains("Не удалось обновить спикера"))
    }

    // MARK: - ImportFileTool

    @Test("import_file returns error for missing file_path")
    func testImportFileMissingPath() throws {

        let result = try ImportFileTool.run(params: [:])
        #expect(result.contains("Error"))
        #expect(result.contains("file_path"))
    }

    @Test("import_file returns error for unsupported format")
    func testImportFileUnsupportedFormat() throws {

        // Create a temp file with unsupported extension
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.pdf")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let params: [String: AnyCodable] = ["file_path": .string(tmpFile.path)]
        let result = try ImportFileTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("unsupported format"))
    }

    /// Egypt goes to summer time at 00:00, so 24 April 2026 has no midnight
    /// there; the day must still be accepted (same rule as the app's parser).
    @Test("a plain date is valid on a day without midnight")
    func testDateOnlyValidOnADayWithoutMidnight() throws {
        let cairo = try #require(TimeZone(identifier: "Africa/Cairo"))
        #expect(ImportFileTool.isValidDate("2026-04-24", timeZone: cairo))
        #expect(ImportFileTool.isValidDate("2026-04-24T15:00:00", timeZone: cairo))
        #expect(!ImportFileTool.isValidDate("24.04.2026", timeZone: cairo))
        #expect(!ImportFileTool.isValidDate("2026-04-24T", timeZone: cairo))
    }

    @Test("import_file returns error for nonexistent file")
    func testImportFileNotFound() throws {

        // A unique name and a stubbed app: a file that happens to exist at a
        // fixed path would send a real import to the running Vedivox.
        let params: [String: AnyCodable] = ["file_path": .string("/tmp/vedivox-test-\(UUID().uuidString).mp3")]
        let result = try withStubbedApp { try ImportFileTool.run(params: params) }
        #expect(result.contains("Error"))
        #expect(result.contains("file not found"))
    }

    @Test("import_file sends the file and reports the app's answer")
    func testImportFileHappyPath() throws {

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("meeting.m4a")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let captured = CapturedCommand()
        let result = try withStubbedApp(
            capturing: captured,
            answering: { _ in AppCommandResponse(ok: true, message: "Импортировано: meeting.m4a", reason: nil) }
        ) {
            try ImportFileTool.run(params: ["file_path": .string(tmpFile.path)])
        }

        #expect(captured.value?.command == AppCommandName.importFile)
        #expect(captured.params["path"] == tmpFile.path)
        #expect(result == "Импортировано: meeting.m4a")
    }

    @Test("import_file surfaces a failed import instead of reporting success")
    func testImportFileFailureIsReported() throws {

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("broken.m4a")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let result = try withStubbedApp(
            answering: { _ in AppCommandResponse(ok: false, message: "Импорт не удался", reason: "failed") }
        ) {
            try ImportFileTool.run(params: ["file_path": .string(tmpFile.path)])
        }

        #expect(result.contains("Error"))
        #expect(result.contains("Импорт не удался"))
    }

    @Test("import_file carries the title")
    func testImportFileWithTitle() throws {

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("call.mp3")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let captured = CapturedCommand()
        _ = try withStubbedApp(capturing: captured) {
            try ImportFileTool.run(
                params: ["file_path": .string(tmpFile.path), "title": .string("Team standup")]
            )
        }
        #expect(captured.params["title"] == "Team standup")
    }

    @Test("import_file includes date in URL when provided")
    func testImportFileWithDate() throws {

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("call2.mp3")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let captured = CapturedCommand()
        _ = try withStubbedApp(capturing: captured) {
            try ImportFileTool.run(
                params: ["file_path": .string(tmpFile.path), "date": .string("2026-07-10")]
            )
        }
        #expect(captured.params["date"] == "2026-07-10")
    }

    // MARK: - ImportYouTubeTool

    @Test("import_youtube returns error for missing url")
    func testImportYouTubeMissingURL() throws {

        let result = try ImportYouTubeTool.run(params: [:])
        #expect(result.contains("Error"))
        #expect(result.contains("url"))
    }

    @Test("import_youtube rejects non-YouTube URL")
    func testImportYouTubeWrongHost() throws {

        let params: [String: AnyCodable] = ["url": .string("https://vimeo.com/12345")]
        let result = try ImportYouTubeTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("not a YouTube URL"))
    }

    @Test("import_youtube reports missing yt-dlp with install hint")
    func testImportYouTubeNoYtDlp() throws {

        let saved = ImportYouTubeTool.locateYtDlp
        ImportYouTubeTool.locateYtDlp = { nil }
        defer { ImportYouTubeTool.locateYtDlp = saved }

        let params: [String: AnyCodable] = ["url": .string("https://www.youtube.com/watch?v=abc")]
        let result = try ImportYouTubeTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("brew install yt-dlp"))
    }

    @Test("import_youtube surfaces yt-dlp failure text")
    func testImportYouTubeDownloadFails() throws {

        let savedLocate = ImportYouTubeTool.locateYtDlp
        let savedFfmpeg = ImportYouTubeTool.locateFfmpeg
        let savedDownload = ImportYouTubeTool.download
        ImportYouTubeTool.locateYtDlp = { "/usr/bin/true" }
        ImportYouTubeTool.locateFfmpeg = { "/usr/bin/true" }
        let folder = CapturedURL()
        ImportYouTubeTool.download = { _, _, dir in
            folder.value = dir.path
            throw ImportYouTubeTool.DownloadError("Private video. Sign in if you've been granted access")
        }
        defer {
            ImportYouTubeTool.locateYtDlp = savedLocate
            ImportYouTubeTool.locateFfmpeg = savedFfmpeg
            ImportYouTubeTool.download = savedDownload
        }

        let params: [String: AnyCodable] = ["url": .string("https://youtu.be/abc")]
        let result = try ImportYouTubeTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("Private video"))
        let dir = try #require(folder.value)
        #expect(!FileManager.default.fileExists(atPath: dir), "a failed download must remove its folder")
    }

    @Test("import_youtube hands the download to import_file with title and upload date")
    func testImportYouTubeHappyPath() throws {

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("ytvideo.m4a")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let savedLocate = ImportYouTubeTool.locateYtDlp
        let savedFfmpeg = ImportYouTubeTool.locateFfmpeg
        let savedDownload = ImportYouTubeTool.download
        let captured = CapturedCommand()
        ImportYouTubeTool.locateYtDlp = { "/usr/bin/true" }
        ImportYouTubeTool.locateFfmpeg = { "/usr/bin/true" }
        let folder = CapturedURL()
        ImportYouTubeTool.download = { _, _, dir in
            folder.value = dir.path
            return ImportYouTubeTool.DownloadResult(
                filePath: tmpFile.path, videoTitle: "Weekly Sync", uploadDate: "20260710"
            )
        }
        defer {
            ImportYouTubeTool.locateYtDlp = savedLocate
            ImportYouTubeTool.locateFfmpeg = savedFfmpeg
            ImportYouTubeTool.download = savedDownload
        }

        let params: [String: AnyCodable] = ["url": .string("https://www.youtube.com/watch?v=abc123")]
        let result = try withStubbedApp(capturing: captured) {
            try ImportYouTubeTool.run(params: params)
        }
        #expect(result.contains("Weekly Sync"))
        #expect(captured.value?.command == AppCommandName.importFile)
        #expect(captured.params["path"] == tmpFile.path)
        // The video title is what the app is told, not only what the tool prints.
        #expect(captured.params["title"] == "Weekly Sync")
        #expect(captured.params["date"] == "2026-07-10")
        let dir = try #require(folder.value)
        #expect(URL(fileURLWithPath: dir).lastPathComponent.hasPrefix("vedivox-youtube."))
        #expect(!FileManager.default.fileExists(atPath: dir), "the folder goes once the app has answered")
    }

    @Test("import_youtube downloads into a private folder per run under $TMPDIR")
    func testImportYouTubeDownloadDirectoryPerRun() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let first = try ImportYouTubeTool.makeDownloadDirectory(environment: ["TMPDIR": base.path])
        let second = try ImportYouTubeTool.makeDownloadDirectory(environment: ["TMPDIR": base.path])
        #expect(first != second)
        for dir in [first, second] {
            #expect(dir.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path)
            #expect(dir.lastPathComponent.hasPrefix("vedivox-youtube."))
            let mode = try #require(fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int)
            #expect(mode == 0o700)
        }

        let fallback = try ImportYouTubeTool.makeDownloadDirectory(environment: [:])
        defer { try? fm.removeItem(at: fallback) }
        #expect(fallback.deletingLastPathComponent().standardizedFileURL.path
            == fm.temporaryDirectory.standardizedFileURL.path)
    }

    @Test("import_youtube sweeps day-old download folders, its own prefix only")
    func testImportYouTubePurgesStaleFolders() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let old = Date().addingTimeInterval(-2 * 24 * 3600)
        func folder(_ name: String, modified: Date?) throws -> URL {
            let url = base.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
            return url
        }
        let stale = try folder("vedivox-youtube.AAAAAA", modified: old)
        let legacy = try folder("vedivox-youtube", modified: old)
        let fresh = try folder("vedivox-youtube.BBBBBB", modified: nil)
        let foreign = try folder("someone-else", modified: old)

        let made = try ImportYouTubeTool.makeDownloadDirectory(environment: ["TMPDIR": base.path])
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(!fm.fileExists(atPath: legacy.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: foreign.path))
        #expect(fm.fileExists(atPath: made.path))
    }

    @Test("import_youtube names the folder when it cannot create it")
    func testImportYouTubeDownloadDirectoryUnavailable() throws {
        // A regular file where $TMPDIR should be a folder: mkdtemp fails.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        do {
            _ = try ImportYouTubeTool.makeDownloadDirectory(environment: ["TMPDIR": blocker.path])
            Issue.record("expected a DownloadError")
        } catch {
            #expect(error.message.hasPrefix("cannot create a temporary folder \(blocker.path)/vedivox-youtube.XXXXXX — "))
        }
    }

    /// yt-dlp loads `yt-dlp.conf` from its working directory, and a config line
    /// such as `--exec` runs a command: started in the caller's directory (a
    /// cloned repository), the download would execute whatever lies there.
    @Test("yt-dlp runs inside its own download folder, not the caller's directory")
    func testYouTubeDownloadRunsInItsOwnFolder() throws {
        let fm = FileManager.default
        let dir = try ScratchDirectory.make(prefix: "vedivox-test")
        defer { try? fm.removeItem(at: dir) }
        // Stands in for yt-dlp: answers the three --print lines, the first
        // being where it was started and whether stdin is the caller's.
        let fake = dir.appendingPathComponent("fake-yt-dlp")
        try Data("#!/bin/sh\npwd -P\nif [ -t 0 ] || [ -p /dev/stdin ]; then echo inherited; else echo detached; fi\necho NA\n".utf8)
            .write(to: fake)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let result = try ImportYouTubeTool.download(fake.path, "https://youtu.be/abc123", dir)

        #expect(URL(fileURLWithPath: result.filePath).resolvingSymlinksInPath().path
            == dir.resolvingSymlinksInPath().path)
        #expect(result.videoTitle == "detached")
    }

    @Test("import_youtube explicit title and date override video metadata")
    func testImportYouTubeExplicitOverrides() throws {

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("ytvideo2.m4a")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let savedLocate = ImportYouTubeTool.locateYtDlp
        let savedFfmpeg = ImportYouTubeTool.locateFfmpeg
        let savedDownload = ImportYouTubeTool.download
        let captured = CapturedCommand()
        ImportYouTubeTool.locateYtDlp = { "/usr/bin/true" }
        ImportYouTubeTool.locateFfmpeg = { "/usr/bin/true" }
        ImportYouTubeTool.download = { _, _, _ in
            ImportYouTubeTool.DownloadResult(
                filePath: tmpFile.path, videoTitle: "Raw upload name", uploadDate: "20260712"
            )
        }
        defer {
            ImportYouTubeTool.locateYtDlp = savedLocate
            ImportYouTubeTool.locateFfmpeg = savedFfmpeg
            ImportYouTubeTool.download = savedDownload
        }

        let params: [String: AnyCodable] = [
            "url": .string("https://youtu.be/abc123"),
            "title": .string("Планёрка DE"),
            "date": .string("2026-07-01"),
        ]
        _ = try withStubbedApp(capturing: captured) {
            try ImportYouTubeTool.run(params: params)
        }
        #expect(captured.params["date"] == "2026-07-01")
        #expect(captured.params["title"] == "Планёрка DE")
    }

    @Test("import_youtube rejects playlist and channel URLs")
    func testImportYouTubePlaylistRejected() throws {

        for url in [
            "https://www.youtube.com/playlist?list=PL12345",
            "https://www.youtube.com/@somechannel",
            "https://www.youtube.com/watch?list=PL12345",
        ] {
            let result = try ImportYouTubeTool.run(params: ["url": .string(url)])
            #expect(result.contains("Error"))
            #expect(result.contains("playlists and channels are not supported"))
        }
    }

    @Test("import_youtube reports missing ffmpeg with install hint")
    func testImportYouTubeNoFfmpeg() throws {

        let savedLocate = ImportYouTubeTool.locateYtDlp
        let savedFfmpeg = ImportYouTubeTool.locateFfmpeg
        ImportYouTubeTool.locateYtDlp = { "/usr/bin/true" }
        ImportYouTubeTool.locateFfmpeg = { nil }
        defer {
            ImportYouTubeTool.locateYtDlp = savedLocate
            ImportYouTubeTool.locateFfmpeg = savedFfmpeg
        }

        let params: [String: AnyCodable] = ["url": .string("https://youtu.be/abc")]
        let result = try ImportYouTubeTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("brew install ffmpeg"))
    }

    @Test("import_youtube rejects malformed date before downloading")
    func testImportYouTubeInvalidDate() throws {

        let savedLocate = ImportYouTubeTool.locateYtDlp
        let savedFfmpeg = ImportYouTubeTool.locateFfmpeg
        let savedDownload = ImportYouTubeTool.download
        ImportYouTubeTool.locateYtDlp = { "/usr/bin/true" }
        ImportYouTubeTool.locateFfmpeg = { "/usr/bin/true" }
        ImportYouTubeTool.download = { _, _, _ in
            Issue.record("download must not run for an invalid date")
            throw ImportYouTubeTool.DownloadError("unreachable")
        }
        defer {
            ImportYouTubeTool.locateYtDlp = savedLocate
            ImportYouTubeTool.locateFfmpeg = savedFfmpeg
            ImportYouTubeTool.download = savedDownload
        }

        let params: [String: AnyCodable] = [
            "url": .string("https://youtu.be/abc"),
            "date": .string("10.07.2026"),
        ]
        let result = try ImportYouTubeTool.run(params: params)
        #expect(result.contains("Error"))
        #expect(result.contains("invalid date"))
    }

    @Test("import_file rejects a malformed date without reaching Vedivox")
    func testImportFileInvalidDate() throws {

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("call3.mp3")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let params: [String: AnyCodable] = [
            "file_path": .string(tmpFile.path),
            "date": .string("07/10/2026"),
        ]
        let result = try withStubbedApp(
            answering: { _ in
                Issue.record("a malformed date must be refused before the app is asked")
                return AppCommandResponse(ok: true, message: "", reason: nil)
            }
        ) {
            try ImportFileTool.run(params: params)
        }

        #expect(result.contains("Error"))
        #expect(result.contains("invalid date"))
    }

    @Test("import_file accepts advertised date formats")
    func testImportFileISODateVariants() throws {

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("call4.mp3")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let captured = CapturedCommand()
        try withStubbedApp(capturing: captured) {
            for date in ["2026-07-10", "2026-07-10T15:30:00Z", "2026-07-10T15:30:00.123Z", "2026-07-10T15:30:00"] {
                let params: [String: AnyCodable] = [
                    "file_path": .string(tmpFile.path),
                    "date": .string(date),
                ]
                let result = try ImportFileTool.run(params: params)
                #expect(!result.contains("Error"), "date \(date) should be accepted")
                #expect(captured.params["date"] == date)
            }
        }
    }

    @Test("import_file surfaces an unreachable app")
    func testImportFileOpenFails() throws {

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("call5.mp3")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let params: [String: AnyCodable] = ["file_path": .string(tmpFile.path)]
        let result = try withStubbedApp(
            answering: { _ in throw AppCommandError.launchFailed("open завершился с кодом 1") }
        ) {
            try ImportFileTool.run(params: params)
        }

        #expect(result.contains("Error"))
        #expect(result.contains("could not launch Vedivox"))
    }

    // MARK: - GetTranscriptTool

    @Test("get_transcript returns formatted transcript")
    func testGetTranscript() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "M", status: "done")
        let speakerId = try insertSpeaker(db: db, name: "Alice")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 0, endTime: 5, text: "Hello there")

        let params: [String: AnyCodable] = ["meeting_id": .string(meetingId)]
        let result = try GetTranscriptTool.run(params: params, db: db)
        #expect(result.contains("Hello there"))
        #expect(result.contains("Alice"))
    }

    @Test("get_transcript with from/to filters by time range")
    func testGetTranscriptTimeRange() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "M", status: "done")
        let speakerId = try insertSpeaker(db: db, name: "Alice")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 0, endTime: 10, text: "First segment")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 30, endTime: 40, text: "Second segment")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 60, endTime: 70, text: "Third segment")

        // from=25 to=45 should return only the second segment
        let params: [String: AnyCodable] = [
            "meeting_id": .string(meetingId),
            "from": .double(25.0),
            "to": .double(45.0),
        ]
        let result = try GetTranscriptTool.run(params: params, db: db)
        #expect(!result.contains("First segment"))
        #expect(result.contains("Second segment"))
        #expect(!result.contains("Third segment"))
    }

    @Test("get_transcript with only from parameter")
    func testGetTranscriptFromOnly() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "M", status: "done")
        let speakerId = try insertSpeaker(db: db, name: "Alice")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 0, endTime: 10, text: "Early")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 60, endTime: 70, text: "Late")

        let params: [String: AnyCodable] = [
            "meeting_id": .string(meetingId),
            "from": .double(50.0),
        ]
        let result = try GetTranscriptTool.run(params: params, db: db)
        #expect(!result.contains("Early"))
        #expect(result.contains("Late"))
    }

    @Test("get_transcript with only to parameter")
    func testGetTranscriptToOnly() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "M", status: "done")
        let speakerId = try insertSpeaker(db: db, name: "Alice")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 0, endTime: 10, text: "Early")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 60, endTime: 70, text: "Late")

        let params: [String: AnyCodable] = [
            "meeting_id": .string(meetingId),
            "to": .double(15.0),
        ]
        let result = try GetTranscriptTool.run(params: params, db: db)
        #expect(result.contains("Early"))
        #expect(!result.contains("Late"))
    }

    @Test("get_transcript from/to works when JSON sends integers (not doubles)")
    func testGetTranscriptTimeRangeWithIntegers() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "M", status: "done")
        let speakerId = try insertSpeaker(db: db, name: "Alice")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 0, endTime: 10, text: "First segment")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 30, endTime: 40, text: "Second segment")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId, speakerLabel: "Alice", startTime: 60, endTime: 70, text: "Third segment")

        // JSON integer values (AnyCodable stores as Int, not Double)
        let params: [String: AnyCodable] = [
            "meeting_id": .string(meetingId),
            "from": .int(25),
            "to": .int(45),
        ]
        let result = try GetTranscriptTool.run(params: params, db: db)
        #expect(!result.contains("First segment"))
        #expect(result.contains("Second segment"))
        #expect(!result.contains("Third segment"))
    }

    @Test("get_transcript merges consecutive segments from same speaker within 20s gap")
    func testGetTranscriptMergesSegments() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "M", status: "done")
        let alice = try insertSpeaker(db: db, name: "Alice")
        let bob = try insertSpeaker(db: db, name: "Bob")

        // Alice: 3 consecutive segments within 20s gap → should merge
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: alice, speakerLabel: "Alice", startTime: 0, endTime: 5, text: "Hello")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: alice, speakerLabel: "Alice", startTime: 5, endTime: 10, text: "world")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: alice, speakerLabel: "Alice", startTime: 10, endTime: 15, text: "today")
        // Bob interrupts
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: bob, speakerLabel: "Bob", startTime: 15, endTime: 20, text: "Hey")
        // Alice again
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: alice, speakerLabel: "Alice", startTime: 20, endTime: 25, text: "Bye")

        let params: [String: AnyCodable] = ["meeting_id": .string(meetingId)]
        let result = try GetTranscriptTool.run(params: params, db: db)

        // Alice's first 3 segments merged into one line
        #expect(result.contains("Alice: Hello world today"))
        // Bob separate
        #expect(result.contains("Bob: Hey"))
        // Alice's last segment separate (different block after Bob)
        #expect(result.contains("Alice: Bye"))
    }

    @Test("get_transcript does not merge same speaker with gap > 20s")
    func testGetTranscriptNoMergeOnLargeGap() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, title: "M", status: "done")
        let alice = try insertSpeaker(db: db, name: "Alice")

        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: alice, speakerLabel: "Alice", startTime: 0, endTime: 5, text: "First")
        // 30s gap — should NOT merge
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: alice, speakerLabel: "Alice", startTime: 35, endTime: 40, text: "Second")

        let params: [String: AnyCodable] = ["meeting_id": .string(meetingId)]
        let result = try GetTranscriptTool.run(params: params, db: db)

        // Should be two separate lines, not merged
        #expect(!result.contains("First Second"))
        #expect(result.contains("Alice: First"))
        #expect(result.contains("Alice: Second"))
    }
}
