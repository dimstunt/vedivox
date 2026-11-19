import Foundation
import Testing
@testable import VedivoxCLIKit
@testable import VedivoxMCPLib

// MARK: - CLIRuntime stubbing

/// Swaps both CLIRuntime seams for the body: app liveness and the command
/// channel. Restores on exit so global state never leaks between tests.
/// CLIRuntime's stubs are process-global, and Swift Testing runs suites in
/// parallel — without a lock one test's dead-app stub leaks into another
/// (seen as flaky 4-7 issue runs). Every test that touches the globals goes
/// through here, so one lock serializes exactly the racing set.
private let cliRuntimeLock = NSLock()

private func withCLIRuntime<T>(
    serving: Bool,
    answering: @escaping @Sendable (AppCommandRequest) throws -> AppCommandResponse = { request in
        AppCommandResponse(ok: true, message: "Готово: \(request.command)", reason: nil)
    },
    capturing captured: CapturedCommand? = nil,
    _ body: () throws -> T
) rethrows -> T {
    _ = appIsOffLimits
    cliRuntimeLock.lock()
    let savedAlive = CLIRuntime.isAppServing
    let savedSend = CLIRuntime.sendCommand
    let savedLong = CLIRuntime.sendLongCommand
    CLIRuntime.isAppServing = { serving }
    CLIRuntime.sendCommand = { request in
        captured?.value = request
        return try answering(request)
    }
    CLIRuntime.sendLongCommand = CLIRuntime.sendCommand
    defer {
        CLIRuntime.isAppServing = savedAlive
        CLIRuntime.sendCommand = savedSend
        CLIRuntime.sendLongCommand = savedLong
        cliRuntimeLock.unlock()
    }
    return try body()
}

private func parseJSON(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

// MARK: - 3.7 exit codes + --json

@Suite("CLI exit codes and JSON output")
struct CLIExitCodeTests {

    @Test("code 2: unknown meeting id")
    func notFound() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "AAAA1111-0000-0000-0000-000000000001")
        #expect(throws: CLIFailure.notFound("no meeting with id starting with ZZZZ")) {
            _ = try CLICommands.status(idPrefix: "ZZZZ", json: false, db: db)
        }
    }

    @Test("code 1: ambiguous prefix refuses and lists candidates off stdout")
    func ambiguous() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "AAAA1111-0000-0000-0000-000000000001", title: "One")
        _ = try insertMeeting(db: db, id: "AAAA2222-0000-0000-0000-000000000002", title: "Two")
        do {
            _ = try CLICommands.status(idPrefix: "AAAA", json: false, db: db)
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            // The candidate listing is part of the FAILURE (→ stderr), never a
            // returned stdout document.
            #expect(failure.code == 1)
            #expect(failure.message.contains("AAAA1111"))
            #expect(failure.message.contains("AAAA2222"))
        }
    }

    @Test("code 64: empty meeting id and empty meeting-set")
    func usage() throws {
        let db = try makeTestDB()
        do {
            _ = try resolveMeeting(idPrefix: "", db: db)
            Issue.record("expected usage failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
        }
        do {
            _ = try CLIActionCore.meetingSet(
                meetingId: "x", title: nil, description: nil, seriesId: nil, db: db
            )
            Issue.record("expected usage failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
        }
    }

    @Test("code 64: unknown list status and an empty transcript range")
    func usageFilters() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "AAAA1111-0000-0000-0000-000000000001")
        _ = try insertMeeting(db: db, id: "BBBB2222-0000-0000-0000-000000000002", status: "needsAttention")
        let attention = try CLICommands.list(
            statuses: ["needsAttention"], dateFrom: nil, dateTo: nil, series: nil, speaker: nil,
            limit: 20, sort: "newest", json: true, db: db
        )
        #expect(attention.contains("BBBB2222"))
        do {
            _ = try CLICommands.list(
                statuses: ["nonsense"], dateFrom: nil, dateTo: nil, series: nil, speaker: nil,
                limit: 20, sort: "newest", json: true, db: db
            )
            Issue.record("expected usage failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
        }
        do {
            _ = try CLICommands.transcript(
                idPrefix: "AAAA", from: 10, to: 5, includeExcluded: false, json: true, db: db
            )
            Issue.record("expected usage failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
        }
    }

    @Test("code 3: lower-layer unavailability maps to 3")
    func unavailable() {
        #expect(cliFailure(from: MCPError.databaseNotFound(path: "/x")).code == 3)
        let dead = AppCommandResponse(ok: false, message: "Vedivox is not answering", reason: "unreachable")
        #expect(cliFailure(from: dead)?.code == 3)
    }

    @Test("every --json document parses whole")
    func jsonParses() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, id: "BBBB1111-0000-0000-0000-000000000001", title: "JSON")
        let speakerId = try insertSpeaker(db: db, name: "Alice")
        try insertMeetingSpeaker(db: db, meetingId: meetingId, speakerId: speakerId)
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId,
                              speakerLabel: "Alice", text: "hello json")
        try syncFTS(db: db)

        let documents = try withCLIRuntime(serving: false) {
            [
                try CLICommands.list(statuses: [], dateFrom: nil, dateTo: nil, series: nil,
                                     speaker: nil, limit: 10, sort: "newest", json: true, db: db),
                try CLICommands.statusOverview(json: true, db: db),
                try CLICommands.status(idPrefix: "BBBB", json: true, db: db),
                try CLICommands.transcript(idPrefix: "BBBB", from: nil, to: nil,
                                           includeExcluded: false, json: true, db: db),
                try CLICommands.search(query: "hello", limit: 5, includeExcluded: false,
                                       json: true, db: db),
                try CLICommands.speakers(meetingIdPrefix: nil, json: true, db: db),
                try CLICommands.series(json: true, db: db),
                try CLICommands.search(query: "hello", limit: 5, includeExcluded: false,
                                       meetings: true, json: true, db: db),
            ]
        }
        // --meetings answers with the `list` document, the line mode keeps its own.
        #expect(documents[7] == documents[0])
        #expect(documents[4].contains("\"meeting_title\""))
        for document in documents {
            _ = try parseJSON(document)
        }
        // Machine keys are snake_case (design § решение 6).
        #expect(documents[0].contains("\"start_time\""))
        #expect(documents[1].contains("\"app_running\""))
    }

    /// the reason is a new key; the old ones stay as they were.
    @Test("show: status_reason only when the meeting has one")
    func showStatusReason() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "CCCC-1", title: "Lost", status: "needsAttention",
                              statusReason: "system, mic compression")
        _ = try insertMeeting(db: db, id: "DDDD-1", title: "Old", status: "needsAttention")

        let json = try #require(try parseJSON(CLICommands.show(idPrefix: "CCCC", json: true, db: db)) as? [String: Any])
        #expect(json["status_reason"] as? String == "system, mic compression")
        #expect(json["status"] as? String == "needsAttention")
        #expect(try CLICommands.show(idPrefix: "CCCC", json: false, db: db)
            .contains("reason: system, mic compression"))

        let old = try #require(try parseJSON(CLICommands.show(idPrefix: "DDDD", json: true, db: db)) as? [String: Any])
        #expect(old["status_reason"] == nil)
        #expect(!(try CLICommands.show(idPrefix: "DDDD", json: false, db: db)).contains("reason:"))
    }
}

// MARK: - 4.4 meeting resolution by prefix

@Suite("Meeting resolution by id prefix")
struct ResolveMeetingTests {

    @Test("one match resolves")
    func unique() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, id: "CCCC1111-0000-0000-0000-000000000001")
        #expect(try resolveMeeting(idPrefix: "CCCC", db: db).id == id)
    }

    @Test("zero matches → code 2")
    func none() throws {
        let db = try makeTestDB()
        do {
            _ = try resolveMeeting(idPrefix: "DDDD", db: db)
            Issue.record("expected not-found")
        } catch let failure as CLIFailure {
            #expect(failure.code == 2)
        }
    }

    @Test("several matches → code 1, nothing acted on")
    func many() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "EEEE1111-0000-0000-0000-000000000001")
        _ = try insertMeeting(db: db, id: "EEEE2222-0000-0000-0000-000000000002")
        do {
            _ = try resolveMeeting(idPrefix: "EEEE", db: db)
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
        }
    }

    /// With one meeting in the database `vedivox meeting delete % --yes` used to
    /// resolve to it: the prefix went into LIKE as a pattern.
    @Test("LIKE wildcards in the prefix match nothing", arguments: ["%", "_", "F_FF", "%0001"])
    func wildcards(prefix: String) throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "FFFF1111-0000-0000-0000-000000000001")
        #expect(throws: CLIFailure.notFound("no meeting with id starting with \(prefix)")) {
            _ = try resolveMeeting(idPrefix: prefix, db: db)
        }
    }

    @Test("the prefix ignores letter case")
    func caseInsensitive() throws {
        let db = try makeTestDB()
        let id = try insertMeeting(db: db, id: "ABCD1111-0000-0000-0000-000000000001")
        #expect(try resolveMeeting(idPrefix: "abcd", db: db).id == id)
    }
}

// MARK: - 5.10 liveness in status

@Suite("Status liveness")
struct StatusLivenessTests {

    @Test("live app: recording shown with elapsed from the meeting's own start")
    func liveRecording() throws {
        let db = try makeTestDB()
        let start = Date(timeIntervalSince1970: 1_756_600_000)
        _ = try insertMeeting(db: db, id: "F0000001-0000-0000-0000-000000000001",
                              title: "Live", startTime: start, durationSeconds: nil,
                              status: "recording")
        let text = try withCLIRuntime(serving: true) {
            try CLICommands.statusOverview(json: true, db: db, now: start.addingTimeInterval(90))
        }
        let object = try #require(try parseJSON(text) as? [String: Any])
        #expect(object["app_running"] as? Bool == true)
        let recording = try #require(object["recording"] as? [String: Any])
        #expect(recording["elapsed_seconds"] as? Int == 90)
    }

    @Test("dead app: no meeting is ever shown as recording, actives are stalled")
    func deadApp() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "F0000002-0000-0000-0000-000000000002",
                              title: "Ghost", status: "recording")
        _ = try insertMeeting(db: db, id: "F0000003-0000-0000-0000-000000000003",
                              title: "Stuck", status: "diarizing")
        let text = try withCLIRuntime(serving: false) {
            try CLICommands.statusOverview(json: true, db: db)
        }
        let object = try #require(try parseJSON(text) as? [String: Any])
        #expect(object["app_running"] as? Bool == false)
        #expect(object["recording"] == nil)
        let processing = try #require(object["processing"] as? [[String: Any]])
        #expect(processing.count == 2)
        #expect(processing.allSatisfy { $0["stalled"] as? Bool == true })
    }

    @Test("single-meeting status marks a dead active meeting as stalled")
    func singleStalled() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "F0000004-0000-0000-0000-000000000004",
                              title: "T", status: "transcribing")
        let text = try withCLIRuntime(serving: false) {
            try CLICommands.status(idPrefix: "F0000004", json: false, db: db)
        }
        #expect(text.contains("stalled"))
    }
}

// MARK: - 5.11 CLI/MCP parity

@Suite("CLI and MCP return the same data")
struct CLIMCPParityTests {

    @Test("transcript blocks match get_transcript")
    func transcript() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, id: "AB000001-0000-0000-0000-000000000001",
                                          title: "Parity")
        let speakerId = try insertSpeaker(db: db, name: "Bob")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId,
                              speakerLabel: "Bob", startTime: 0, endTime: 4, text: "first line")
        _ = try insertSegment(db: db, meetingId: meetingId, speakerId: speakerId,
                              speakerLabel: "Bob", startTime: 100, endTime: 104, text: "second line")

        let cli = try CLICommands.transcript(idPrefix: "AB000001", from: nil, to: nil,
                                             includeExcluded: false, json: true, db: db)
        let mcp = try GetTranscriptTool.run(params: ["meeting_id": .string(meetingId)], db: db)

        let object = try #require(try parseJSON(cli) as? [String: Any])
        let blocks = try #require(object["blocks"] as? [[String: Any]])
        #expect(!blocks.isEmpty)
        for block in blocks {
            let text = try #require(block["text"] as? String)
            #expect(mcp.contains(text), "block text must appear in MCP transcript")
        }
    }

    @Test("speakers list matches list_speakers")
    func speakers() throws {
        let db = try makeTestDB()
        let meetingId = try insertMeeting(db: db, id: "AB000002-0000-0000-0000-000000000002")
        for name in ["Alice", "Bob"] {
            let speakerId = try insertSpeaker(db: db, name: name)
            try insertMeetingSpeaker(db: db, meetingId: meetingId, speakerId: speakerId)
        }
        let cli = try CLICommands.speakers(meetingIdPrefix: nil, json: true, db: db)
        let mcp = try ListSpeakersTool.run(params: [:], db: db)

        let rows = try #require(try parseJSON(cli) as? [[String: Any]])
        #expect(rows.count == 2)
        for row in rows {
            let name = try #require(row["name"] as? String)
            #expect(mcp.contains(name), "speaker must appear in MCP list")
        }
    }

    /// Speaker commands take a full id and do not resolve prefixes: with the
    /// 8-character form in this listing, `vedivox speaker merge <target> one meeting`
    /// named nobody and the app still answered "Merged".
    @Test("vedivox speakers prints the id the speaker commands accept")
    func speakersListFullIds() throws {
        let db = try makeTestDB()
        let id = try insertSpeaker(db: db, id: "5E1E0000-0000-0000-0000-00000000000A", name: "Alice")
        let text = try CLICommands.speakers(meetingIdPrefix: nil, json: false, db: db)
        #expect(text.contains(id))
    }
}

// MARK: - 7.8 action outcome reporting

@Suite("Action commands report the app's outcome")
struct CLIActionTests {

    @Test("transcribe sends the absolute path and prints merged speaker turns")
    func transcribeMergesTurns() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vedivox-cli-test-\(UUID()).m4a")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let segments = #"[{"speaker":"A","from":0,"to":2,"text":"one"},{"speaker":"A","from":3,"to":4,"text":"two"},"#
            + #"{"speaker":"A","from":40,"to":41,"text":"later"},{"speaker":"B","from":41,"to":42,"text":"other"}]"#
        let captured = CapturedCommand()
        let result = try withCLIRuntime(
            serving: true,
            answering: { _ in AppCommandResponse(ok: true, message: "ok", reason: nil, data: ["segments": segments]) },
            capturing: captured,
            { try CLIActionCore.transcribe(source: file.path, json: false) }
        )
        #expect(captured.value?.command == AppCommandName.transcribeFile)
        #expect(captured.value?.params["path"] == file.path)
        #expect(result.split(separator: "\n").map(String.init) == [
            "[00:00:00 → 00:00:04] A: one two",
            "[00:00:40 → 00:00:41] A: later",
            "[00:00:41 → 00:00:42] B: other",
        ])
    }

    @Test("success relays the app's answer for THIS request")
    func success() throws {
        let db = try makeTestDB()
        for id in ["T", "S"] { _ = try insertSpeaker(db: db, id: id) }
        let captured = CapturedCommand()
        let result = try withCLIRuntime(
            serving: true,
            answering: { _ in AppCommandResponse(ok: true, message: "Merged 1 speaker(s) into T", reason: nil) },
            capturing: captured,
            { try CLIActionCore.speakerMerge(targetId: "T", sourceIds: ["S"], confirmed: true, db: db) }
        )
        // The output is the app's own report of this request, verbatim.
        #expect(result == "Merged 1 speaker(s) into T")
        #expect(captured.value?.params["target_id"] == "T")
        #expect(captured.value?.params["source_ids"] == "S")
    }

    @Test("rename sends confirmed only when asked")
    func renameConfirm() throws {
        for (flag, expected) in [(false, String?.none), (true, String?("1"))] {
            let captured = CapturedCommand()
            _ = try withCLIRuntime(
                serving: true,
                answering: { _ in AppCommandResponse(ok: true, message: "Updated speaker T", reason: nil) },
                capturing: captured,
                { try CLIActionCore.speakerRename(speakerId: "T", name: "X", confirmed: flag) }
            )
            #expect(captured.value?.params["name"] == "X")
            // Absent, not "0": the app treats any other value as no-op, but an
            // absent key is what the pre-flag CLI sent.
            #expect(captured.value?.params["confirmed"] == expected)
        }
    }

    @Test("refusal → nonzero code with the reason")
    func refusal() throws {
        do {
            _ = try withCLIRuntime(
                serving: true,
                answering: { _ in AppCommandResponse(ok: false, message: "Speaker T not found", reason: "not_found") },
                { try CLIActionCore.speakerRename(speakerId: "T", name: "X", confirmed: false) }
            )
            Issue.record("expected failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 2)
            #expect(failure.message.contains("not_found"))
        }
    }

    @Test("app unreachable → code 3")
    func unreachable() throws {
        do {
            _ = try withCLIRuntime(
                serving: false,
                answering: { _ in AppCommandResponse(ok: false, message: "Vedivox is not answering", reason: "unreachable") },
                { try CLIActionCore.speakerRename(speakerId: "T", name: "X", confirmed: false) }
            )
            Issue.record("expected failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 3)
        }
    }

    @Test("invalid merge arguments → code 64, nothing sent")
    func badMerge() throws {
        let db = try makeTestDB()
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIActionCore.speakerMerge(targetId: "T", sourceIds: ["T"], confirmed: false, db: db)
            }
            Issue.record("expected usage failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
            #expect(captured.value == nil, "invalid request must not reach the app")
        }
    }

    @Test("ambiguous detach meeting prefix resolves nothing and sends nothing")
    func ambiguousDetach() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "AD000001-0000-0000-0000-000000000001")
        _ = try insertMeeting(db: db, id: "AD000002-0000-0000-0000-000000000002")
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIActionCore.speakerDetach(speakerId: "S", meetingPrefixes: ["AD"], db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(captured.value == nil)
        }
    }
}

// MARK: - speaker delete

@Suite("CLI speaker delete")
struct CLISpeakerDeleteTests {
    @Test("unknown id is code 2; without --yes code 1 and nothing sent; with --yes one request")
    func deleteFlow() throws {
        let db = try makeTestDB()
        let id = try insertSpeaker(db: db, name: "Clara")
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIActionCore.speakerDelete(speakerId: "nope", confirmed: true, db: db)
            }
            Issue.record("expected not found")
        } catch let failure as CLIFailure {
            #expect(failure.code == 2)
        }
        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIActionCore.speakerDelete(speakerId: id, confirmed: false, db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("--yes"))
            #expect(failure.message.contains("Clara"))
        }
        #expect(captured.value == nil)

        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.speakerDelete(speakerId: id, confirmed: true, db: db)
        }
        #expect(captured.value?.command == AppCommandName.deleteSpeaker)
        #expect(captured.value?.params == ["speaker_id": id])
    }
}

// MARK: - series apply-rules

@Suite("CLI series apply-rules")
struct CLISeriesApplyRulesTests {
    @Test("without --yes: a dry run, refused with the count; nothing to assign is fine; --yes assigns")
    func applyRules() throws {
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, answering: { _ in
                AppCommandResponse(ok: true, message: "would assign 3 meeting(s)", reason: nil, data: ["assigned": "3"])
            }, capturing: captured) {
                try CLIActionCore.seriesApplyRules(confirmed: false)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("would assign 3"))
            #expect(failure.message.contains("--yes"))
        }
        #expect(captured.value?.params == ["dry_run": "1"])

        let none = try withCLIRuntime(serving: true, answering: { _ in
            AppCommandResponse(ok: true, message: "would assign 0 meeting(s)", reason: nil, data: ["assigned": "0"])
        }) {
            try CLIActionCore.seriesApplyRules(confirmed: false)
        }
        #expect(none == "would assign 0 meeting(s)")

        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.seriesApplyRules(confirmed: true)
        }
        #expect(captured.value?.command == AppCommandName.applySeriesRules)
        // The app treats anything but an explicit "0" as a dry run.
        #expect(captured.value?.params == ["dry_run": "0"])
    }
}

// MARK: - meeting delete

@Suite("CLI meeting delete")
struct CLIMeetingDeleteTests {
    private let first = "DE100001-0000-0000-0000-000000000001"
    private let second = "DE200002-0000-0000-0000-000000000002"

    private func db() throws -> DatabaseReader {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: first, title: "Standup")
        _ = try insertMeeting(db: db, id: second, title: "Retro")
        return db
    }

    @Test("without --yes: code 1, lists prefix and title, nothing sent")
    func needsYes() throws {
        let db = try db()
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIActionCore.meetingDelete(meetingIds: ["DE1", "DE2"], confirmed: false, json: false, db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("--yes"))
            #expect(failure.message.contains("DE100001  Standup"))
            #expect(failure.message.contains("DE200002  Retro"))
        }
        #expect(captured.value == nil)
    }

    @Test("with --yes: one request with every full id, one line per meeting; --json lists full ids")
    func deletes() throws {
        let db = try db()
        let captured = CapturedCommand()
        let text = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.meetingDelete(meetingIds: ["de1", "DE2", "DE100001"], confirmed: true, json: false, db: db)
        }
        #expect(captured.value?.command == AppCommandName.deleteMeetings)
        #expect(captured.value?.params == ["meeting_ids": "\(first),\(second)"])
        #expect(text == "deleted DE100001  Standup\ndeleted DE200002  Retro")

        let json = try withCLIRuntime(serving: true) {
            try CLIActionCore.meetingDelete(meetingIds: ["DE2"], confirmed: true, json: true, db: db)
        }
        #expect(json == "{\"deleted\":[\"\(second)\"]}")
    }

    @Test("an unknown id is code 2, an ambiguous one code 1; the other ids are not deleted")
    func resolvesAllFirst() throws {
        let db = try db()
        let captured = CapturedCommand()
        for (ids, code) in [(["DE1", "nope"], Int32(2)), (["DE1", "DE"], Int32(1))] {
            do {
                _ = try withCLIRuntime(serving: true, capturing: captured) {
                    try CLIActionCore.meetingDelete(meetingIds: ids, confirmed: true, json: false, db: db)
                }
                Issue.record("expected failure for \(ids)")
            } catch let failure as CLIFailure {
                #expect(failure.code == code)
            }
        }
        #expect(captured.value == nil)
    }

    @Test("the app refusing a busy meeting is code 1")
    func busyRefused() throws {
        let db = try db()
        do {
            _ = try withCLIRuntime(serving: true, answering: { _ in
                AppCommandResponse(ok: false, message: "Meeting is recording; nothing deleted", reason: "not_ready")
            }) {
                try CLIActionCore.meetingDelete(meetingIds: ["DE1"], confirmed: true, json: false, db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
        }
    }
}

// MARK: - marks / segment / series actions

@Suite("CLI mark, unmark, segment set, series create")
struct CLIMarkActionTests {
    @Test("mark: request carries the resolved meeting id, seconds as strings, and the track")
    func mark() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "DDDD1111-0000-0000-0000-000000000001")
        let captured = CapturedCommand()
        let result = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.markExcluded(meetingId: "DDDD", from: 10, to: 12.5, track: "system", db: db)
        }
        #expect(result.hasPrefix("Готово"))
        #expect(captured.value?.command == AppCommandName.markExcluded)
        #expect(captured.value?.params["meeting_id"] == "DDDD1111-0000-0000-0000-000000000001")
        #expect(captured.value?.params["from"] == "10.0")
        #expect(captured.value?.params["to"] == "12.5")
        #expect(captured.value?.params["track"] == "system")
    }

    @Test("unmark by id sends mark_id only; by range sends from/to; segment set and series create pass through")
    func shapes() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "DDDD1111-0000-0000-0000-000000000001")
        let captured = CapturedCommand()
        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.unmark(meetingId: "DDDD", markId: 7, from: 1, to: 2, track: "mic", db: db)
        }
        #expect(captured.value?.command == AppCommandName.unmark)
        #expect(captured.value?.params["mark_id"] == "7")
        #expect(captured.value?.params["from"] == nil)
        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.unmark(meetingId: "DDDD", markId: nil, from: 1, to: 2, track: nil, db: db)
        }
        #expect(captured.value?.params["from"] == "1.0")
        #expect(captured.value?.params["to"] == "2.0")
        #expect(captured.value?.params["mark_id"] == nil)
        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.segmentSet(segmentId: 42, speakerId: "SPK")
        }
        #expect(captured.value?.command == AppCommandName.updateSegment)
        #expect(captured.value?.params["segment_id"] == "42")
        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.seriesCreate(name: "121 Test", calendarSeriesId: "cal-1")
        }
        #expect(captured.value?.command == AppCommandName.createSeries)
        #expect(captured.value?.params["calendar_series_id"] == "cal-1")
    }

    @Test("series set and delete resolve the series prefix (any case) and carry only the passed fields")
    func seriesShapes() throws {
        let db = try makeTestDB()
        let id = try insertSeries(db: db, id: "5E1E0000-0000-0000-0000-000000000001", name: "121 Test")
        let captured = CapturedCommand()
        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.seriesSet(seriesId: "5e1e", name: "121 Глеб", calendarSeriesId: nil, autoRule: "", db: db)
        }
        #expect(captured.value?.command == AppCommandName.updateSeries)
        #expect(captured.value?.params["series_id"] == id)
        #expect(captured.value?.params["name"] == "121 Глеб")
        #expect(captured.value?.params["auto_rule_pattern"] == "")
        #expect(captured.value?.params["calendar_series_id"] == nil)
        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.seriesDelete(seriesId: "5E1E", confirmed: true, db: db)
        }
        #expect(captured.value?.command == AppCommandName.deleteSeries)
        #expect(captured.value?.params == ["series_id": id])
    }

    /// merge names what would change and exits 1 without --yes, like delete.
    @Test("series merge: without --yes code 1 and nothing sent; with --yes full ids; same series is 64")
    func seriesMerge() throws {
        let db = try makeTestDB()
        let source = try insertSeries(db: db, id: "D0B10000-0000-0000-0000-000000000001", name: "Design review")
        let target = try insertSeries(db: db, id: "0RIG0000-0000-0000-0000-000000000001", name: "design review")
        _ = try insertMeeting(db: db, title: "M1", seriesId: source)
        _ = try insertMeeting(db: db, title: "M2", seriesId: source)
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIActionCore.seriesMerge(sourceId: "d0b1", targetId: "0RIG", confirmed: false, db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("--yes"))
            #expect(failure.message.contains("2 meetings move"))
            #expect(failure.message.contains("D0B10000  Design review"))
            #expect(failure.message.contains("→ 0RIG0000  design review"))
        }
        #expect(captured.value == nil)

        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIActionCore.seriesMerge(sourceId: "d0b1", targetId: "0RIG", confirmed: true, db: db)
        }
        #expect(captured.value?.command == AppCommandName.mergeSeries)
        #expect(captured.value?.params == ["source_id": source, "target_id": target])

        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIActionCore.seriesMerge(sourceId: "D0B1", targetId: "d0b10000", confirmed: true, db: db)
            }
            Issue.record("expected usage error")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
        }
    }

    @Test("series delete: an unknown id is code 2, an ambiguous prefix is code 1 and nothing is sent")
    func seriesResolution() throws {
        let db = try makeTestDB()
        _ = try insertSeries(db: db, id: "AAAA0000-0000-0000-0000-000000000001", name: "one")
        _ = try insertSeries(db: db, id: "AAAA0000-0000-0000-0000-000000000002", name: "two")
        let captured = CapturedCommand()
        for (prefix, code) in [("nope", 2), ("AAAA", 1)] {
            do {
                _ = try withCLIRuntime(serving: true, capturing: captured) {
                    try CLIActionCore.seriesDelete(seriesId: prefix, confirmed: true, db: db)
                }
                Issue.record("expected failure for \(prefix)")
            } catch let failure as CLIFailure {
                #expect(failure.code == code)
            }
        }
        #expect(captured.value == nil)
    }

    @Test("code 64 before any lookup: to <= from, unmark without id or range, blank series name")
    func usage() throws {
        let db = try makeTestDB()
        let bodies: [() throws -> String] = [
            { try CLIActionCore.markExcluded(meetingId: "no-such", from: 5, to: 5, track: nil, db: db) },
            { try CLIActionCore.unmark(meetingId: "no-such", markId: nil, from: nil, to: nil, track: nil, db: db) },
            { try CLIActionCore.seriesCreate(name: "   ", calendarSeriesId: nil) },
            { try CLIActionCore.seriesSet(seriesId: "x", name: nil, calendarSeriesId: nil, autoRule: nil, db: db) },
            { try CLIActionCore.seriesSet(seriesId: "x", name: " ", calendarSeriesId: nil, autoRule: nil, db: db) },
        ]
        for body in bodies {
            do {
                _ = try body()
                Issue.record("expected usage failure")
            } catch let failure as CLIFailure {
                #expect(failure.code == 64)
            }
        }
    }
}

// MARK: - vedivox record start|stop

@Suite("CLI record start and stop")
struct CLIRecordTests {
    private static let started: @Sendable (AppCommandRequest) -> AppCommandResponse = { _ in
        AppCommandResponse(
            ok: true, message: "Recording started: M1", reason: nil,
            data: ["meeting_id": "M1", "system_audio": "1"]
        )
    }

    @Test("start sends start_recording with the title and prints the app's message")
    func startText() throws {
        let captured = CapturedCommand()
        let result = try withCLIRuntime(serving: true, answering: Self.started, capturing: captured) {
            try CLIActionCore.recordStart(title: "cli-check", json: false)
        }
        #expect(result == "Recording started: M1")
        #expect(captured.value?.command == AppCommandName.startRecording)
        #expect(captured.value?.params == ["title": "cli-check"])
    }

    @Test("start --json prints one document from the reply's data; no title sends no title")
    func startJSON() throws {
        let captured = CapturedCommand()
        let micOnly: @Sendable (AppCommandRequest) -> AppCommandResponse = { _ in
            AppCommandResponse(
                ok: true, message: "Recording started: M2 (microphone only: system audio unavailable)",
                reason: nil, data: ["meeting_id": "M2", "system_audio": "0"]
            )
        }
        let full = try withCLIRuntime(serving: true, answering: Self.started, capturing: captured) {
            try CLIActionCore.recordStart(title: nil, json: true)
        }
        #expect(captured.value?.params == [:])
        #expect(full == #"{"meeting_id":"M1","system_audio":true}"#)
        let partial = try withCLIRuntime(serving: true, answering: micOnly) {
            try CLIActionCore.recordStart(title: nil, json: true)
        }
        #expect(partial == #"{"meeting_id":"M2","system_audio":false}"#)
    }

    @Test("refusals: not_ready and failed are code 1, unreachable is code 3 — nothing reaches stdout")
    func startRefusals() throws {
        // executeCore prints only a returned value, so a throw means empty stdout.
        for (reason, code) in [("not_ready", Int32(1)), ("failed", 1), ("unreachable", 3)] {
            do {
                _ = try withCLIRuntime(
                    serving: true,
                    answering: { _ in AppCommandResponse(ok: false, message: "Already recording M1", reason: reason) },
                    { try CLIActionCore.recordStart(title: nil, json: true) }
                )
                Issue.record("expected failure for \(reason)")
            } catch let failure as CLIFailure {
                #expect(failure.code == code)
                #expect(failure.message.contains("Already recording M1"))
            }
        }
    }

    @Test("mute-debug prints the app's report and never launches the app")
    func muteDebug() throws {
        let captured = CapturedCommand()
        let report = try withCLIRuntime(
            serving: true,
            answering: { _ in AppCommandResponse(ok: true, message: "Teams: pid 1, state via reader: muted", reason: nil) },
            capturing: captured,
            { try CLIActionCore.muteDebug() }
        )
        #expect(captured.value?.command == AppCommandName.diagnoseMute)
        #expect(report == "Teams: pid 1, state via reader: muted")

        let none = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: false, capturing: none) { try CLIActionCore.muteDebug() }
            Issue.record("expected unavailable")
        } catch let failure as CLIFailure {
            #expect(failure.code == 3)
            #expect(none.value == nil)
        }
    }

    @Test("audio compact without a running app is unavailable (3) and sends nothing")
    func compactWithoutApp() throws {
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: false, capturing: captured) {
                try CLIActionCore.audioCompact(dryRun: true, json: false)
            }
            Issue.record("expected unavailable")
        } catch let failure as CLIFailure {
            #expect(failure.code == 3)
            #expect(captured.value == nil, "compact must not launch or reach the app")
        }
    }

    @Test("audio compact --dry-run sends dry_run=1; --json decodes the report")
    func compactDryRun() throws {
        let captured = CapturedCommand()
        let result = try withCLIRuntime(
            serving: true,
            answering: { _ in AppCommandResponse(ok: true, message: "Would compact 2 track(s)", reason: nil, data: [
                "dry_run": "1", "tracks_compacted": "2", "bytes_before": "100", "bytes_after": "40", "bytes_freed": "60",
                "anomalies": "M1/system.m4a: zero size\nM2/mic.m4a.bak",
            ]) },
            capturing: captured,
            { try CLIActionCore.audioCompact(dryRun: true, json: true) }
        )
        #expect(captured.value?.command == AppCommandName.compactAudio)
        #expect(captured.value?.params["dry_run"] == "1")
        let object = try #require(try parseJSON(result) as? [String: Any])
        #expect(object["bytes_freed"] as? Int == 60)
        #expect((object["anomalies"] as? [String])?.count == 2)
    }

    @Test("audio compact with failed tracks exits 1")
    func compactPartial() throws {
        do {
            _ = try withCLIRuntime(
                serving: true,
                answering: { _ in AppCommandResponse(ok: false, message: "Failed, originals kept", reason: "failed", data: nil) },
                { try CLIActionCore.audioCompact(dryRun: false, json: false) }
            )
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.output == nil, "no report without --json")
        }
    }

    @Test("audio compact --json with failed tracks still prints the report and exits 1")
    func compactPartialJSON() throws {
        do {
            _ = try withCLIRuntime(
                serving: true,
                answering: { _ in AppCommandResponse(ok: false, message: "Failed, originals kept", reason: "failed", data: [
                    "tracks_compacted": "3", "tracks_failed": "1", "failed": "M1/mic.m4a: too short",
                ]) },
                { try CLIActionCore.audioCompact(dryRun: false, json: true) }
            )
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            let output = try #require(failure.output)
            let object = try #require(try parseJSON(output) as? [String: Any])
            #expect(object["tracks_failed"] as? Int == 1)
            #expect(object["failed"] as? [String] == ["M1/mic.m4a: too short"])
        }
    }

    @Test("stop without a running app refuses with code 1 and sends nothing")
    func stopWithoutApp() throws {
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: false, capturing: captured) {
                try CLIActionCore.recordStop(json: false)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(captured.value == nil, "stop must not launch or reach the app")
        }
    }

    @Test("stop with a running app sends stop_recording; --json carries only meeting_id")
    func stop() throws {
        let captured = CapturedCommand()
        let result = try withCLIRuntime(
            serving: true,
            answering: { _ in AppCommandResponse(ok: true, message: "Recording stopped: M1", reason: nil, data: ["meeting_id": "M1"]) },
            capturing: captured,
            { try CLIActionCore.recordStop(json: true) }
        )
        #expect(captured.value?.command == AppCommandName.stopRecording)
        #expect(result == #"{"meeting_id":"M1"}"#)
    }

    @Test("unknown flag is a usage error (64) before anything runs")
    func usage() {
        do {
            _ = try VedivoxCommand.parseAsRoot(["record", "start", "--bogus"])
            Issue.record("expected a parse error")
        } catch {
            #expect(VedivoxCommand.exitCode(for: error).rawValue == 64)
        }
    }
}

// MARK: - vedivox live

/// The app's answer to `live_transcript` for a recording 754 s in.
private func liveAnswer(turns: String = #"[{"speaker":{"kind":"known","name":"Alice","confidence":0.82},"track":"system","from":725,"to":731.4,"text":"какой у нас срок?"},{"speaker":{"kind":"me","name":"me"},"track":"mic","from":733,"to":736,"text":"до пятницы"}]"#,
                        state: String = "ready", dropped: String = "0.0") -> AppCommandResponse {
    AppCommandResponse(ok: true, message: "Live transcript: 2 turn(s), recognition ready", reason: nil, data: [
        "meeting_id": "M1", "state": state, "elapsed": "754.2", "dropped_seconds": dropped, "turns": turns,
    ])
}

@Suite("vedivox live")
struct CLILiveTests {

    @Test("the whole recording: turns in order, each after who said it, under a header that says it is preliminary")
    func wholeRecording() throws {
        let captured = CapturedCommand()
        let text = try withCLIRuntime(serving: true, answering: { _ in liveAnswer() }, capturing: captured) {
            try CLIActionCore.live(last: nil, json: false)
        }
        #expect(captured.value?.command == AppCommandName.liveTranscript)
        #expect(captured.value?.params == [:], "no window is sent for the whole recording")
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].contains("M1") && lines[0].contains("00:12:34") && lines[0].contains("Preliminary"))
        #expect(lines[1] == "[00:12:05] Alice: какой у нас срок?")
        #expect(lines[2] == "[00:12:13] me: до пятницы")
    }

    @Test("--last 5m asks the app for the last 300 seconds")
    func lastWindow() throws {
        let captured = CapturedCommand()
        _ = try withCLIRuntime(serving: true, answering: { _ in liveAnswer() }, capturing: captured) {
            try CLIActionCore.live(last: "5m", json: false)
        }
        #expect(captured.value?.params["last"].flatMap(Double.init) == 300)
    }

    @Test("--precise asks the app to refine the stretch first; a plain reading never does")
    func precise() throws {
        let captured = CapturedCommand()
        _ = try withCLIRuntime(serving: true, answering: { _ in liveAnswer() }, capturing: captured) {
            try CLIActionCore.live(last: "5m", json: false, precise: true)
        }
        #expect(captured.value?.params == ["last": "300.0", "precise": "1"])
        _ = try VedivoxCommand.parseAsRoot(["live", "--last", "5m", "--precise"])

        let plain = CapturedCommand()
        _ = try withCLIRuntime(serving: true, answering: { _ in liveAnswer() }, capturing: plain) {
            try CLIActionCore.live(last: "5m", json: false)
        }
        #expect(plain.value?.params["precise"] == nil)

        let mcp = CapturedCommand()
        _ = try withStubbedApp(capturing: mcp, answering: { _ in liveAnswer() }) {
            GetLiveTranscriptTool.run(params: ["precise": .bool(true)])
        }
        #expect(mcp.value?.params == ["precise": "1"])
    }

    @Test("--json is one document with the meeting, the state, the clock, the loss and the turns")
    func json() throws {
        let output = try withCLIRuntime(serving: true, answering: { _ in liveAnswer(dropped: "2.5") }) {
            try CLIActionCore.live(last: nil, json: true)
        }
        let object = try #require(try parseJSON(output) as? [String: Any])
        #expect(Set(object.keys) == ["meeting_id", "state", "elapsed", "dropped_seconds", "turns"])
        #expect(object["meeting_id"] as? String == "M1")
        #expect(object["state"] as? String == "ready")
        #expect(object["elapsed"] as? Double == 754.2)
        #expect(object["dropped_seconds"] as? Double == 2.5)
        let turns = try #require(object["turns"] as? [[String: Any]])
        #expect(turns.count == 2)
        let speaker = try #require(turns[0]["speaker"] as? [String: Any])
        #expect(speaker["kind"] as? String == "known")
        #expect(speaker["name"] as? String == "Alice")
        #expect(speaker["confidence"] as? Double == 0.82)
        let owner = try #require(turns[1]["speaker"] as? [String: Any])
        #expect(Set(owner.keys) == ["kind", "name"], "no confidence where no name is claimed")
        #expect(turns[0]["track"] as? String == "system")
        #expect(turns[0]["from"] as? Double == 725)
        #expect(turns[0]["text"] as? String == "какой у нас срок?")
    }

    @Test("a voice without a name reads as Speaker N, speech nobody was told apart in as others")
    func unnamedVoices() throws {
        let turns = #"[{"speaker":{"kind":"unknown","name":"Speaker 2"},"track":"system","from":10,"to":14,"text":"раз"},"#
            + #"{"speaker":{"kind":"unknown","name":"others"},"track":"system","from":40,"to":41,"text":"два"}]"#
        let text = try withCLIRuntime(serving: true, answering: { _ in liveAnswer(turns: turns) }) {
            try CLIActionCore.live(last: nil, json: false)
        }
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.suffix(2) == ["[00:00:10] Speaker 2: раз", "[00:00:40] others: два"])
    }

    @Test("an app not relaunched since the update still labels by track: its answer is read, not refused")
    func answerOfAnOlderApp() throws {
        let turns = #"[{"speaker":"others","track":"system","from":725,"to":731.4,"text":"какой у нас срок?"},"#
            + #"{"speaker":"me","track":"mic","from":733,"to":736,"text":"до пятницы"}]"#
        let text = try withCLIRuntime(serving: true, answering: { _ in liveAnswer(turns: turns) }) {
            try CLIActionCore.live(last: nil, json: false)
        }
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.suffix(2) == ["[00:12:05] others: какой у нас срок?", "[00:12:13] me: до пятницы"])

        let json = try withCLIRuntime(serving: true, answering: { _ in liveAnswer(turns: turns) }) {
            try CLIActionCore.live(last: nil, json: true)
        }
        let object = try #require(try parseJSON(json) as? [String: Any])
        let speakers = try #require(object["turns"] as? [[String: Any]]).compactMap { $0["speaker"] as? [String: String] }
        #expect(speakers == [["kind": "unknown", "name": "others"], ["kind": "me", "name": "me"]])
    }

    @Test("nobody spoke: an empty list in JSON, a plain sentence for a reader, exit 0")
    func noSpeech() throws {
        let json = try withCLIRuntime(serving: true, answering: { _ in liveAnswer(turns: "[]") }) {
            try CLIActionCore.live(last: "1m", json: true)
        }
        let object = try #require(try parseJSON(json) as? [String: Any])
        #expect((object["turns"] as? [Any])?.isEmpty == true)

        let text = try withCLIRuntime(serving: true, answering: { _ in liveAnswer(turns: "[]") }) {
            try CLIActionCore.live(last: "1m", json: false)
        }
        #expect(text.contains("No speech in this stretch."))
    }

    @Test("a model still loading and skipped audio are said in words, so an empty text is not misread")
    func caveats() throws {
        let text = try withCLIRuntime(
            serving: true, answering: { _ in liveAnswer(turns: "[]", state: "loading", dropped: "12.0") }
        ) {
            try CLIActionCore.live(last: nil, json: false)
        }
        #expect(text.contains("still loading"))
        #expect(text.contains("skipped 12 s"))
        #expect(!text.contains("No speech"))
    }

    @Test("without a running app: refusal, code 1, nothing sent, nothing launched")
    func withoutApp() throws {
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: false, capturing: captured) {
                try CLIActionCore.live(last: nil, json: false)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("nothing is recording"))
            #expect(captured.value == nil)
        }
    }

    @Test("nothing recording: the app's refusal comes back as code 1 with its words")
    func nothingRecording() throws {
        do {
            _ = try withCLIRuntime(
                serving: true,
                answering: { _ in AppCommandResponse(ok: false, message: "Nothing is recording", reason: "not_ready") }
            ) {
                try CLIActionCore.live(last: nil, json: true)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("Nothing is recording"))
        }
    }

    @Test("an app build without the command: code 1 and a reason a person can act on")
    func oldBuild() throws {
        do {
            _ = try withCLIRuntime(
                serving: true,
                answering: { _ in
                    AppCommandResponse(ok: false, message: "Unknown command: live_transcript", reason: "unknown_command")
                }
            ) {
                try CLIActionCore.live(last: nil, json: false)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("update the app"))
        }
    }

    @Test("a window without a unit, negative or not a number is a usage error (64) before anything is sent",
          arguments: ["5", "-5m", "abc", "5 minutes", "m", "inf" + "m"])
    func badWindow(raw: String) throws {
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIActionCore.live(last: raw, json: false)
            }
            Issue.record("expected a usage error for \(raw)")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
            #expect(captured.value == nil)
        }
    }

    @Test("durations: seconds, minutes, hours, fractions, case and spaces")
    func durations() {
        #expect(LiveTranscript.seconds(fromDuration: "90s") == 90)
        #expect(LiveTranscript.seconds(fromDuration: "5m") == 300)
        #expect(LiveTranscript.seconds(fromDuration: "1h") == 3600)
        #expect(LiveTranscript.seconds(fromDuration: "1.5m") == 90)
        #expect(LiveTranscript.seconds(fromDuration: " 2M ") == 120)
        #expect(LiveTranscript.seconds(fromDuration: "0s") == 0)
    }

    @Test("`vedivox live --last 5m --json` parses; an unknown flag is a usage error")
    func parsing() throws {
        _ = try VedivoxCommand.parseAsRoot(["live", "--last", "5m", "--json"])
        do {
            _ = try VedivoxCommand.parseAsRoot(["live", "--since", "60"])
            Issue.record("expected a parse error")
        } catch {
            #expect(VedivoxCommand.exitCode(for: error).rawValue == 64)
        }
    }

    @Test("the MCP tool gives the same turns as the command line for the same answer")
    func sameTurnsThroughMCP() throws {
        let cli = try withCLIRuntime(serving: true, answering: { _ in liveAnswer() }) {
            try CLIActionCore.live(last: "5m", json: false)
        }
        let captured = CapturedCommand()
        let mcp = try withStubbedApp(capturing: captured, answering: { _ in liveAnswer() }) {
            GetLiveTranscriptTool.run(params: ["last": .string("5m")])
        }
        #expect(mcp == cli)
        #expect(captured.value?.command == AppCommandName.liveTranscript)
        #expect(captured.value?.params["last"].flatMap(Double.init) == 300)
    }

    @Test("the MCP tool does not launch the app, and passes the app's refusal on with its reason")
    func mcpRefusals() throws {
        let notRunning = try withStubbedApp(serving: false) { GetLiveTranscriptTool.run(params: [:]) }
        #expect(notRunning == "Error: Vedivox is not running; nothing is recording")

        let idle = try withStubbedApp(answering: { _ in
            AppCommandResponse(ok: false, message: "Nothing is recording", reason: "not_ready")
        }) { GetLiveTranscriptTool.run(params: [:]) }
        #expect(idle == "Error: Nothing is recording [not_ready]")

        let badWindow = try withStubbedApp { GetLiveTranscriptTool.run(params: ["last": .string("5")]) }
        #expect(badWindow.hasPrefix("Error: last must be a number with a unit"))
    }
}

// MARK: - vedivox feedback

@Suite("vedivox feedback archive")
struct CLIFeedbackTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vedivox-fb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func zipEntries(_ zip: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", zip]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return out.split(separator: "\n").map(String.init)
    }

    private func unzippedSystemText(_ zip: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        let name = URL(fileURLWithPath: zip).deletingPathExtension().lastPathComponent
        process.arguments = ["-p", zip, "\(name)/system.txt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return out
    }

    @Test("full set: notes, every vedivox*.log, system.txt; never the database or audio")
    func fullSet() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data")
        try write("note", root.appendingPathComponent("notes/2026-10-01-crash.md"))
        try write("log0", data.appendingPathComponent("logs/vedivox.log"))
        try write("log1", data.appendingPathComponent("logs/vedivox.1.log"))
        try write("db", data.appendingPathComponent("Vedivox.sqlite"))
        try write("wal", data.appendingPathComponent("Vedivox.sqlite-wal"))
        try write("audio", data.appendingPathComponent("audio/M1/mic.m4a"))
        let app = root.appendingPathComponent("Vedivox.app")
        let plist: NSDictionary = ["CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "777"]
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let out = root.appendingPathComponent("out")

        let db = try makeTestDB()
        let path = try withCLIRuntime(serving: false) {
            try CLIFeedbackCore.bundle(
                notesDir: root.appendingPathComponent("notes"), logsDir: data.appendingPathComponent("logs"),
                appBundle: app, outputDir: out, json: false, db: { db }
            )
        }
        #expect(path.hasPrefix(out.path + "/vedivox-feedback-") && path.hasSuffix(".zip"))
        let entries = try zipEntries(path)
        #expect(entries.contains { $0.hasSuffix("feedback/2026-10-01-crash.md") })
        #expect(entries.contains { $0.hasSuffix("logs/vedivox.log") })
        #expect(entries.contains { $0.hasSuffix("logs/vedivox.1.log") })
        #expect(entries.contains { $0.hasSuffix("system.txt") })
        #expect(!entries.contains { $0.contains(".sqlite") || $0.contains(".m4a") || $0.contains("/._") })
        let system = try unzippedSystemText(path)
        #expect(system.contains("vedivox: 0.4.0 (777)"))
        #expect(system.contains("app: not running"))
    }

    @Test("no notes, no database: archive still built, system.txt says why; --json gives the path")
    func missingParts() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("log0", root.appendingPathComponent("logs/vedivox.log"))
        let result = try CLIFeedbackCore.bundle(
            notesDir: root.appendingPathComponent("absent"), logsDir: root.appendingPathComponent("logs"),
            appBundle: root.appendingPathComponent("absent.app"), outputDir: root, json: true,
            db: { throw MCPError.databaseNotFound(path: "/nope/Vedivox.sqlite") }
        )
        let path = try #require((try parseJSON(result) as? [String: String])?["path"])
        let system = try unzippedSystemText(path)
        #expect(system.contains("feedback notes: none"))
        #expect(system.contains("vedivox: not installed"))
        #expect(system.contains("status unavailable: database not found at /nope/Vedivox.sqlite"))
    }

    @Test("read-only destination: code 3")
    func readOnlyDestination() throws {
        let root = try tempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        do {
            _ = try CLIFeedbackCore.bundle(
                notesDir: root.appendingPathComponent("absent"), logsDir: root.appendingPathComponent("absent"),
                appBundle: root.appendingPathComponent("absent.app"), outputDir: root, json: false,
                db: { throw MCPError.databaseNotFound(path: "x") }
            )
            Issue.record("expected a failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 3)
        }
    }
}

// MARK: - listen-queue 6.1–6.4

@Suite("Listen queue from the command line")
struct CLIListenTests {

    private let meetingId = "F00D0000-0000-0000-0000-000000000001"
    private let speakerId = "ABCD0000-0000-0000-0000-000000000004"

    private func seeded() throws -> DatabaseReader {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: meetingId, title: "ABC")
        _ = try insertSpeaker(db: db, id: speakerId, name: "speaker_4")
        try insertMeetingSpeaker(db: db, meetingId: meetingId, speakerId: speakerId)
        return db
    }

    @Test("item meetingPrefix:speakerPrefix resolves to full ids; a gone record is code 2")
    func itemResolution() throws {
        let db = try seeded()
        let voice = try CLIListenCore.resolveItem("f00d:abcd", db: db)
        #expect(voice.meetingId == meetingId)
        #expect(voice.speakerId == speakerId)
        #expect(throws: CLIFailure.self) { _ = try CLIListenCore.resolveItem("F00D", db: db) }
        do {
            _ = try CLIListenCore.resolveItem("F00D:9999", db: db)
            Issue.record("expected not found")
        } catch let failure as CLIFailure {
            #expect(failure.code == 2)
        }
    }

    @Test("assign: --speaker and --new together is code 64, nothing sent")
    func assignBothTargets() throws {
        let db = try seeded()
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIListenCore.assign(item: "F00D:ABCD", speakerId: "X", newName: "Y", db: db)
            }
            Issue.record("expected usage failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
        }
        #expect(captured.value == nil)
    }

    @Test("assign and skip carry the resolved pair")
    func assignAndSkipShapes() throws {
        let db = try seeded()
        let captured = CapturedCommand()
        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIListenCore.assign(item: "F00D:ABCD", speakerId: nil, newName: "Ella", db: db)
        }
        #expect(captured.value?.command == AppCommandName.assignVoice)
        #expect(captured.value?.params == ["meeting_id": meetingId, "speaker_id": speakerId, "name": "Ella"])
        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIListenCore.skip(item: "F00D:ABCD", db: db)
        }
        #expect(captured.value?.command == AppCommandName.skipVoice)
    }

    @Test("the app's not_found on a reprocessed voice is code 2")
    func assignGone() throws {
        let db = try seeded()
        do {
            _ = try withCLIRuntime(serving: true, answering: { _ in
                AppCommandResponse(ok: false, message: "No voice", reason: "not_found")
            }) {
                try CLIListenCore.skip(item: "F00D:ABCD", db: db)
            }
            Issue.record("expected not found")
        } catch let failure as CLIFailure {
            #expect(failure.code == 2)
        }
    }

    @Test("queue --json keeps the app's snake_case rows")
    func queueJSON() throws {
        let db = try seeded()
        let items = """
            [{"id":"\(meetingId):\(speakerId)","meeting_id":"\(meetingId)","meeting_title":"ABC",\
            "speaker_id":"\(speakerId)","speaker_label":"speaker_4","seconds":432,"reason":"almost_known",\
            "best_similarity":0.71,"fragment":{"from":724,"to":739,"track":"system"},"line":"hello",\
            "candidates":[{"speaker_id":"S1","name":"Alice","similarity":0.71}],"skipped":false}]
            """
        let captured = CapturedCommand()
        let output = try withCLIRuntime(serving: true, answering: { _ in
            AppCommandResponse(ok: true, message: "1 voice(s)", reason: nil, data: ["items": items])
        }, capturing: captured) {
            try CLIListenCore.queue(meeting: "F00D", limit: 5, skipped: true, json: true, db: db)
        }
        #expect(captured.value?.params == ["meeting_id": meetingId, "limit": "5", "skipped": "1"])
        let rows = try #require(try parseJSON(output) as? [[String: Any]])
        #expect(rows.first?["meeting_id"] as? String == meetingId)
        #expect(rows.first?["best_similarity"] as? Double == 0.71)
        let candidates = try #require(rows.first?["candidates"] as? [[String: Any]])
        #expect(candidates.first?["speaker_id"] as? String == "S1")

        let text = try withCLIRuntime(serving: true, answering: { _ in
            AppCommandResponse(ok: true, message: "", reason: nil, data: ["items": items])
        }) {
            try CLIListenCore.queue(meeting: nil, limit: nil, skipped: false, json: false, db: db)
        }
        #expect(text.contains("F00D0000:ABCD0000"))
        #expect(text.contains("7m 12s"))
    }

    @Test("segment set range: --to ≤ --from is 64 before anything is sent")
    func rangeShape() throws {
        let db = try seeded()
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, capturing: captured) {
                try CLIListenCore.assignRange(meeting: "F00D", from: 10, to: 10, track: nil, speakerId: "S", db: db)
            }
            Issue.record("expected usage failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
        }
        #expect(captured.value == nil)
        _ = try withCLIRuntime(serving: true, capturing: captured) {
            try CLIListenCore.assignRange(meeting: "F00D", from: 724, to: 1170, track: "system", speakerId: "S", db: db)
        }
        #expect(captured.value?.command == AppCommandName.assignRange)
        #expect(captured.value?.params == [
            "meeting_id": meetingId, "from": "724.0", "to": "1170.0", "track": "system", "speaker_id": "S",
        ])
    }

    @Test("pin-speakers without --yes: a dry run, code 1 with the listing")
    func pinWithoutYes() throws {
        let db = try seeded()
        let pins = """
            [{"meeting_id":"\(meetingId)","speaker_id":"S1","name":"Alice","seconds":431,"intervals":12}]
            """
        let captured = CapturedCommand()
        do {
            _ = try withCLIRuntime(serving: true, answering: { _ in
                AppCommandResponse(ok: true, message: "would pin", reason: nil, data: ["pins": pins])
            }, capturing: captured) {
                try CLIListenCore.pinSpeakers(meetings: ["F00D"], confirmed: false, json: false, db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("Alice — 7m 11s in 12 interval(s)"))
        }
        #expect(captured.value?.params["dry_run"] == "1")

        _ = try withCLIRuntime(serving: true, answering: { _ in
            AppCommandResponse(ok: true, message: "pinned", reason: nil, data: ["pins": pins])
        }, capturing: captured) {
            try CLIListenCore.pinSpeakers(meetings: ["F00D"], confirmed: true, json: false, db: db)
        }
        #expect(captured.value?.params["dry_run"] == nil)
    }

    @Test("marks show the verdict's speaker id and name")
    func marksShowVerdictSpeaker() throws {
        let db = try seeded()
        let alice = try insertSpeaker(db: db, name: "Alice")
        _ = try insertMark(db: db, meetingId: meetingId, startTime: 0, endTime: 10, track: "system",
                           kind: "speaker", source: "manual", speakerId: alice)
        _ = try insertMark(db: db, meetingId: meetingId, startTime: 20, endTime: 30)

        let text = try CLICommands.marks(idPrefix: "F00D", json: false, db: db)
        #expect(text.contains("speaker (manual)  → Alice (\(alice))"))
        let rows = try #require(try parseJSON(try CLICommands.marks(idPrefix: "F00D", json: true, db: db)) as? [[String: Any]])
        #expect(rows.first?["speaker_id"] as? String == alice)
        #expect(rows.first?["speaker_name"] as? String == "Alice")
        #expect(rows.last?["speaker_id"] == nil)

        let mcp = try ListMarksTool.run(params: ["meeting_id": .string(meetingId)], db: db)
        #expect(mcp.contains("speaker_id=\(alice) (Alice)"))
    }
}

@Suite("Irreversible commands need --yes")
struct CLIConfirmationTests {
    private let meetingId = "AE100001-0000-0000-0000-000000000001"
    private let seriesId = "5E100001-0000-0000-0000-000000000001"

    @Test("without --yes: code 1 naming the object, nothing sent; with it the command goes")
    func needsYes() throws {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: meetingId, title: "Standup")
        _ = try insertSeries(db: db, id: seriesId, name: "Weekly")
        for id in ["T", "S1", "S2"] { _ = try insertSpeaker(db: db, id: id) }
        let commands: [(String, (Bool) throws -> String)] = [
            ("Standup", { try CLIActionCore.reprocess(meetingId: "AE1", suppressEcho: nil, confirmed: $0, db: db) }),
            ("S1, S2 → T", { try CLIActionCore.speakerMerge(targetId: "T", sourceIds: ["S1", "S2"], confirmed: $0, db: db) }),
            ("Weekly", { try CLIActionCore.seriesDelete(seriesId: "5E1", confirmed: $0, db: db) }),
        ]
        for (named, run) in commands {
            let captured = CapturedCommand()
            do {
                _ = try withCLIRuntime(serving: true, capturing: captured) { try run(false) }
                Issue.record("expected a refusal without --yes for \(named)")
            } catch let failure as CLIFailure {
                #expect(failure.code == 1)
                #expect(failure.message.contains("--yes"))
                #expect(failure.message.contains(named))
            }
            #expect(captured.value == nil, "nothing may reach the app without --yes")
            _ = try withCLIRuntime(serving: true, capturing: captured) { try run(true) }
            #expect(captured.value != nil)
        }
    }

    @Test("a missing meeting is code 2 before the --yes question")
    func notFoundFirst() throws {
        let db = try makeTestDB()
        do {
            _ = try withCLIRuntime(serving: true) {
                try CLIActionCore.reprocess(meetingId: "nope", suppressEcho: nil, confirmed: false, db: db)
            }
            Issue.record("expected not found")
        } catch let failure as CLIFailure {
            #expect(failure.code == 2)
        }
    }

    @Test("speaker merge: an unknown target or source is code 2 before the --yes question, nothing sent")
    func mergeNotFoundFirst() throws {
        let db = try makeTestDB()
        _ = try insertSpeaker(db: db, id: "T")
        let captured = CapturedCommand()
        for (target, sources) in [("nope", ["T"]), ("T", ["nope"])] {
            for confirmed in [false, true] {
                do {
                    _ = try withCLIRuntime(serving: true, capturing: captured) {
                        try CLIActionCore.speakerMerge(targetId: target, sourceIds: sources, confirmed: confirmed, db: db)
                    }
                    Issue.record("expected not found")
                } catch let failure as CLIFailure {
                    #expect(failure.code == 2)
                    #expect(failure.message.contains("nope"))
                }
            }
        }
        #expect(captured.value == nil)
    }

    @Test("a quoted ~ path is expanded, a relative one joins the working directory")
    func absolutePath() {
        #expect(CLIActionCore.absolutePath("~/x.mp3") == NSHomeDirectory() + "/x.mp3")
        #expect(CLIActionCore.absolutePath("/a/b.mp3") == "/a/b.mp3")
        #expect(CLIActionCore.absolutePath("b.mp3") == FileManager.default.currentDirectoryPath + "/b.mp3")
    }
}

// MARK: - Split, trim, merge and undo (cli-meeting-edit)

/// Every request a fake app received, in order.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AppCommandRequest] = []
    func append(_ request: AppCommandRequest) { lock.withLock { requests.append(request) } }
    var all: [AppCommandRequest] { lock.withLock { requests } }
}

/// A fake app that splits and merges as the real one answers: a split keeps
/// the meeting and names a new part; a merge keeps `first_id`.
private func meetingEditApp(_ log: RequestLog, refuseMergeOf: String? = nil) -> @Sendable (AppCommandRequest) throws -> AppCommandResponse {
    { request in
        log.append(request)
        let params = request.params
        switch request.command {
        case AppCommandName.splitMeeting:
            let id = params["meeting_id"] ?? ""
            return AppCommandResponse(ok: true, message: "split at \(params["at"] ?? "")", reason: nil,
                                      data: ["meeting_ids": "\(id),new-\(params["at"] ?? "")"])
        case AppCommandName.mergeMeetings:
            if params["second_id"] == refuseMergeOf {
                return AppCommandResponse(ok: false, message: "Meeting is transcribing", reason: "not_ready")
            }
            return AppCommandResponse(ok: true, message: "merged \(params["second_id"] ?? "")", reason: nil,
                                      data: ["meeting_id": params["first_id"] ?? ""])
        default:
            return AppCommandResponse(ok: true, message: "done", reason: nil, data: ["meeting_ids": "a,b"])
        }
    }
}

@Suite("meeting split, trim, merge and undo")
struct MeetingEditCLITests {
    private func db() throws -> DatabaseReader {
        let db = try makeTestDB()
        _ = try insertMeeting(db: db, id: "AAAA0000-0000-0000-0000-000000000001", title: "Long call",
                              startTime: Date(timeIntervalSince1970: 1000), durationSeconds: 60)
        for start in [0.0, 25, 45] {
            _ = try insertSegment(db: db, meetingId: "AAAA0000-0000-0000-0000-000000000001",
                                  startTime: start, endTime: start + 5, text: "line \(start)")
        }
        _ = try insertMeeting(db: db, id: "BBBB0000-0000-0000-0000-000000000001", title: "Part two",
                              startTime: Date(timeIntervalSince1970: 3000))
        _ = try insertMeeting(db: db, id: "CCCC0000-0000-0000-0000-000000000001", title: "Part one",
                              startTime: Date(timeIntervalSince1970: 2000))
        return db
    }

    @Test("split without --yes lists the parts, exits 1 and sends nothing")
    func splitNeedsYes() throws {
        let db = try db()
        let log = RequestLog()
        do {
            _ = try withCLIRuntime(serving: true, answering: meetingEditApp(log)) {
                try CLIActionCore.meetingSplit(meetingId: "aaaa", at: [40, 20], confirmed: false, json: false, db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("into 3 meetings"))
            #expect(failure.message.contains("part 2  0:20–0:40  1 lines"))
        }
        #expect(log.all.isEmpty)
    }

    @Test("several cut points: checked first, then cut from the last back on the original")
    func splitChain() throws {
        let db = try db()
        let log = RequestLog()
        let output = try withCLIRuntime(serving: true, answering: meetingEditApp(log)) {
            try CLIActionCore.meetingSplit(meetingId: "aaaa", at: [20, 40], confirmed: true, json: true, db: db)
        }
        let id = "AAAA0000-0000-0000-0000-000000000001"
        #expect(log.all.map(\.params) == [["meeting_id": id, "at": "40.0"], ["meeting_id": id, "at": "20.0"]])
        #expect((try parseJSON(output) as? [String: Any])?["meetings"] as? [String] == [id, "new-20.0", "new-40.0"])

        // A part with no line is refused before the first cut.
        do {
            _ = try withCLIRuntime(serving: true, answering: meetingEditApp(log)) {
                try CLIActionCore.meetingSplit(meetingId: "aaaa", at: [10, 20], confirmed: true, json: false, db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 64)
        }
        #expect(log.all.count == 2)
    }

    @Test("merge joins in order of start into the earliest; a refused link names what was done")
    func mergeChain() throws {
        let db = try db()
        let log = RequestLog()
        let output = try withCLIRuntime(serving: true, answering: meetingEditApp(log)) {
            try CLIActionCore.meetingMerge(meetingIds: ["bbbb", "cccc", "aaaa"], confirmed: true, json: true, db: db)
        }
        let (a, b, c) = ("AAAA0000-0000-0000-0000-000000000001", "BBBB0000-0000-0000-0000-000000000001",
                         "CCCC0000-0000-0000-0000-000000000001")
        #expect(log.all.map(\.params) == [["first_id": a, "second_id": c], ["first_id": a, "second_id": b]])
        let json = try #require(try parseJSON(output) as? [String: Any])
        #expect(json["meeting"] as? String == a)
        #expect(json["merged"] as? [String] == [c, b])

        do {
            _ = try withCLIRuntime(serving: true, answering: meetingEditApp(log, refuseMergeOf: b)) {
                try CLIActionCore.meetingMerge(meetingIds: ["aaaa", "bbbb", "cccc"], confirmed: true, json: false, db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("already done"))
            #expect(failure.message.contains("[not_ready]"))
        }
    }

    @Test("trim and undo carry their parameters; a bad kind or nothing to trim is 64")
    func trimAndUndo() throws {
        let db = try db()
        let log = RequestLog()
        _ = try withCLIRuntime(serving: true, answering: meetingEditApp(log)) {
            try CLIActionCore.meetingTrim(meetingId: "aaaa", from: 10, to: nil, confirmed: true, json: false, db: db)
        }
        #expect(log.all.last?.params == ["meeting_id": "AAAA0000-0000-0000-0000-000000000001", "from": "10.0", "to": "60.0"])

        let output = try withCLIRuntime(serving: true, answering: meetingEditApp(log)) {
            try CLIActionCore.meetingUndo(kind: "split", meetingId: "aaaa", confirmed: true, json: true, db: db)
        }
        #expect(log.all.last?.command == AppCommandName.undoMeetingEdit)
        #expect(log.all.last?.params["kind"] == "split")
        #expect((try parseJSON(output) as? [String: Any])?["meetings"] as? [String] == ["a", "b"])

        let count = log.all.count
        let bodies: [() throws -> String] = [
            { try CLIActionCore.meetingTrim(meetingId: "aaaa", from: nil, to: nil, confirmed: true, json: false, db: db) },
            { try CLIActionCore.meetingUndo(kind: "delete", meetingId: "aaaa", confirmed: true, json: false, db: db) },
            { try CLIActionCore.meetingMerge(meetingIds: ["aaaa", "AAAA0000"], confirmed: true, json: false, db: db) },
        ]
        for body in bodies {
            do {
                _ = try withCLIRuntime(serving: true, answering: meetingEditApp(log), body)
                Issue.record("expected usage error")
            } catch let failure as CLIFailure {
                #expect(failure.code == 64)
            }
        }
        do {
            _ = try withCLIRuntime(serving: true, answering: meetingEditApp(log)) {
                try CLIActionCore.meetingUndo(kind: "trim", meetingId: "aaaa", confirmed: false, json: false, db: db)
            }
            Issue.record("expected refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == 1)
            #expect(failure.message.contains("reprocessed"))
        }
        #expect(log.all.count == count)
    }

    /// The MCP tool runs the same chain (spec: CLI and MCP do not diverge).
    @Test("split_meeting tool cuts like the CLI")
    func mcpSplit() throws {
        let db = try db()
        let log = RequestLog()
        let text = try withStubbedApp(answering: meetingEditApp(log)) {
            try MeetingEditTools.split(
                params: ["meeting_id": .string("AAAA0000-0000-0000-0000-000000000001"), "at": .array([.int(20), .double(40)])],
                db: db
            )
        }
        #expect(log.all.map { $0.params["at"] } == ["40.0", "20.0"])
        #expect(text.contains("Split into 3 meetings"))
    }
}
