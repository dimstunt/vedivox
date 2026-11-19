import XCTest

/// Pins the promise that every command is answered.
///
/// The defect this change exists to remove was a handler that returned without
/// saying anything, so "there is no path out of dispatch without a response" is
/// the property worth testing, not the happy path.
@MainActor
final class CommandDispatcherTests: XCTestCase {

    /// Records what dispatch asked for, and answers whatever the test needs.
    private final class FakeExecutor: CommandExecutor {
        var opened: (id: String, seekTime: Double?)?
        var reprocessed: (id: String, suppressEcho: Bool?)?
        var exported: String?
        var imported: (path: String, title: String?, date: String?)?
        var answer: AppCommandResponse = .success("ok")

        func commandOpenMeeting(id: String, seekTime: Double?) async -> AppCommandResponse {
            opened = (id, seekTime)
            return answer
        }

        func commandReprocessMeeting(id: String, suppressEcho: Bool?) async -> AppCommandResponse {
            reprocessed = (id, suppressEcho)
            return answer
        }

        func commandExportMeeting(id: String) async -> AppCommandResponse {
            exported = id
            return answer
        }

        func commandImportFile(path: String, title: String?, date: String?) async -> AppCommandResponse {
            imported = (path, title, date)
            return answer
        }

        var transcribed: String?
        func commandTranscribeFile(path: String) async -> AppCommandResponse {
            transcribed = path
            return answer
        }

        var speakerUpdate: (id: String, fields: [String: String])?
        var merge: (targetId: String, sourceIds: [String])?
        var segmentUpdate: (segmentId: Int64, speakerId: String)?
        var meetingUpdate: (id: String, fields: [String: String])?
        var seriesCreate: (name: String, calendarSeriesId: String?)?

        func commandUpdateSpeaker(id: String, fields: [String: String]) async -> AppCommandResponse {
            speakerUpdate = (id, fields)
            return answer
        }

        func commandMergeSpeakers(targetId: String, sourceIds: [String]) async -> AppCommandResponse {
            merge = (targetId, sourceIds)
            return answer
        }

        var detach: (speakerId: String, meetingIds: [String])?
        func commandDetachMeetings(speakerId: String, meetingIds: [String]) async -> AppCommandResponse {
            detach = (speakerId, meetingIds)
            return answer
        }

        var applyRulesDryRun: Bool?
        func commandApplySeriesRules(dryRun: Bool) async -> AppCommandResponse {
            applyRulesDryRun = dryRun
            return answer
        }

        var deletedSpeaker: String?
        func commandDeleteSpeaker(id: String) async -> AppCommandResponse {
            deletedSpeaker = id
            return answer
        }

        func commandUpdateSegment(segmentId: Int64, speakerId: String) async -> AppCommandResponse {
            segmentUpdate = (segmentId, speakerId)
            return answer
        }

        func commandUpdateMeeting(id: String, fields: [String: String]) async -> AppCommandResponse {
            meetingUpdate = (id, fields)
            return answer
        }

        func commandCreateSeries(name: String, calendarSeriesId: String?) async -> AppCommandResponse {
            seriesCreate = (name, calendarSeriesId)
            return answer
        }

        var seriesUpdate: (id: String, fields: [String: String])?
        var seriesDelete: String?

        func commandUpdateSeries(id: String, fields: [String: String]) async -> AppCommandResponse {
            seriesUpdate = (id, fields)
            return answer
        }

        func commandDeleteSeries(id: String) async -> AppCommandResponse {
            seriesDelete = id
            return answer
        }

        var meetingEdit: (command: String, id: String, values: [String])?
        func commandSplitMeeting(id: String, at time: Double) async -> AppCommandResponse {
            meetingEdit = ("split", id, [String(time)])
            return answer
        }
        func commandTrimMeeting(id: String, from: Double, to: Double) async -> AppCommandResponse {
            meetingEdit = ("trim", id, [String(from), String(to)])
            return answer
        }
        func commandMergeMeetings(firstId: String, secondId: String) async -> AppCommandResponse {
            meetingEdit = ("merge", firstId, [secondId])
            return answer
        }
        func commandUndoMeetingEdit(id: String, kind: String) async -> AppCommandResponse {
            meetingEdit = ("undo", id, [kind])
            return answer
        }

        var seriesMerge: (sourceId: String, targetId: String)?
        func commandMergeSeries(sourceId: String, targetId: String) async -> AppCommandResponse {
            seriesMerge = (sourceId, targetId)
            return answer
        }

        var markExcluded: (meetingId: String, from: Double, to: Double, track: String?)?
        var unmark: (meetingId: String, markId: Int64?, from: Double?, to: Double?, track: String?)?

        func commandMarkExcluded(meetingId: String, from: Double, to: Double, track: String?) async -> AppCommandResponse {
            markExcluded = (meetingId, from, to, track)
            return answer
        }

        func commandUnmark(meetingId: String, markId: Int64?, from: Double?, to: Double?, track: String?) async -> AppCommandResponse {
            unmark = (meetingId, markId, from, to, track)
            return answer
        }

        var started: String??
        var stopped = false

        func commandStartRecording(title: String?) async -> AppCommandResponse {
            started = .some(title)
            return answer
        }

        func commandStopRecording() async -> AppCommandResponse {
            stopped = true
            return answer
        }

        var liveLast: Double??
        var livePrecise: Bool?
        func commandLiveTranscript(last: Double?, precise: Bool) async -> AppCommandResponse {
            liveLast = .some(last)
            livePrecise = precise
            return answer
        }

        var compactDryRun: Bool?
        func commandCompactAudio(dryRun: Bool) async -> AppCommandResponse {
            compactDryRun = dryRun
            return answer
        }

        var deleted: [String]?
        var listen: AppCommandRequest?
        func commandListen(_ request: AppCommandRequest) async -> AppCommandResponse {
            listen = request
            return answer
        }

        func commandDeleteMeetings(ids: [String]) async -> AppCommandResponse {
            deleted = ids
            return answer
        }
    }

    func testRecordingControlReachesTheExecutor() async {
        let executor = FakeExecutor()
        _ = await dispatch(AppCommandName.startRecording, ["title": " acceptance "], executor: executor)
        XCTAssertEqual(executor.started, .some("acceptance"))
        _ = await dispatch(AppCommandName.startRecording, ["title": ""], executor: executor)
        XCTAssertEqual(executor.started, .some(nil))
        _ = await dispatch(AppCommandName.stopRecording, executor: executor)
        XCTAssertTrue(executor.stopped)
    }

    /// Any process of the user can start a recording through the socket, so a
    /// start that went through is announced; a refused start and other
    /// commands are not.
    func testOnlyASuccessfulSocketStartIsAnnounced() {
        let start = AppCommandRequest(command: AppCommandName.startRecording, params: [:])
        let stop = AppCommandRequest(command: AppCommandName.stopRecording, params: [:])
        XCTAssertTrue(CommandDispatcher.announcesRecordingStart(start, .success("Recording started: X")))
        XCTAssertFalse(CommandDispatcher.announcesRecordingStart(start, .failure("Already recording X", reason: .notReady)))
        XCTAssertFalse(CommandDispatcher.announcesRecordingStart(stop, .success("Recording stopped: X")))
    }

    func testLiveTranscriptWindowReachesTheExecutor() async {
        let executor = FakeExecutor()
        _ = await dispatch(AppCommandName.liveTranscript, executor: executor)
        XCTAssertEqual(executor.liveLast, .some(nil), "no window means the whole recording")
        _ = await dispatch(AppCommandName.liveTranscript, ["last": " 300 "], executor: executor)
        XCTAssertEqual(executor.liveLast, .some(300))
    }

    func testAPreciseLiveTranscriptIsAskedForOnlyByAnExplicitYes() async {
        let executor = FakeExecutor()
        _ = await dispatch(AppCommandName.liveTranscript, ["last": "300"], executor: executor)
        XCTAssertEqual(executor.livePrecise, false, "a plain reading never waits for a pass")
        _ = await dispatch(AppCommandName.liveTranscript, ["last": "300", "precise": "1"], executor: executor)
        XCTAssertEqual(executor.livePrecise, true)
        XCTAssertEqual(executor.liveLast, .some(300))
        _ = await dispatch(AppCommandName.liveTranscript, ["precise": "yes please"], executor: executor)
        XCTAssertEqual(executor.livePrecise, false)
    }

    /// A garbled window must not quietly become «the whole recording».
    func testLiveTranscriptRefusesAWindowThatIsNotSeconds() async {
        for bad in ["abc", "-5", "inf", "nan"] {
            let executor = FakeExecutor()
            let response = await dispatch(AppCommandName.liveTranscript, ["last": bad], executor: executor)
            XCTAssertFalse(response.ok, bad)
            XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue, bad)
            XCTAssertNil(executor.liveLast, bad)
        }
    }

    /// `data` is optional on the wire: a reply without it (every other
    /// command, older senders) still decodes, and a nil `data` is not sent.
    func testResponseDataIsOptionalOnTheWire() throws {
        let legacy = try JSONDecoder().decode(AppCommandResponse.self, from: Data(#"{"ok":true,"message":"m"}"#.utf8))
        XCTAssertNil(legacy.data)

        let withData = AppCommandResponse.success("m", data: ["meeting_id": "X"])
        let decoded = try JSONDecoder().decode(AppCommandResponse.self, from: JSONEncoder().encode(withData))
        XCTAssertEqual(decoded, withData)

        let plain = String(bytes: try JSONEncoder().encode(AppCommandResponse.success("m")), encoding: .utf8)
        XCTAssertEqual(plain?.contains("data"), false)
    }

    private func dispatch(
        _ command: String,
        _ params: [String: String] = [:],
        executor: FakeExecutor
    ) async -> AppCommandResponse {
        await CommandDispatcher.dispatch(
            AppCommandRequest(command: command, params: params),
            to: executor
        )
    }

    // MARK: - Routing

    /// The real run is irreversible: only an explicit "0" turns the dry run off.
    func testCompactIsADryRunUnlessExplicitlyNot() async {
        let executor = FakeExecutor()
        _ = await dispatch(AppCommandName.compactAudio, [:], executor: executor)
        XCTAssertEqual(executor.compactDryRun, true)
        _ = await dispatch(AppCommandName.compactAudio, ["dry_run": "no"], executor: executor)
        XCTAssertEqual(executor.compactDryRun, true)
        _ = await dispatch(AppCommandName.compactAudio, ["dry_run": "0"], executor: executor)
        XCTAssertEqual(executor.compactDryRun, false)
    }

    func testReprocessReachesTheExecutor() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.reprocessMeeting, ["meeting_id": "abc"], executor: executor)

        XCTAssertEqual(executor.reprocessed?.id, "abc")
        XCTAssertTrue(response.ok)
    }

    func testExportReachesTheExecutor() async {
        let executor = FakeExecutor()
        _ = await dispatch(AppCommandName.exportMeeting, ["meeting_id": "abc"], executor: executor)
        XCTAssertEqual(executor.exported, "abc")
    }

    func testOpenCarriesTheSeekTime() async {
        let executor = FakeExecutor()
        _ = await dispatch(AppCommandName.openMeeting, ["meeting_id": "abc", "t": "91.5"], executor: executor)

        XCTAssertEqual(executor.opened?.id, "abc")
        XCTAssertEqual(executor.opened?.seekTime, 91.5)
    }

    func testImportCarriesTitleAndDate() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.importFile,
            ["path": "/tmp/call.m4a", "title": "Weekly", "date": "2026-08-14"],
            executor: executor
        )

        XCTAssertEqual(executor.imported?.path, "/tmp/call.m4a")
        XCTAssertEqual(executor.imported?.title, "Weekly")
        XCTAssertEqual(executor.imported?.date, "2026-08-14")
    }

    func testPingIsAnsweredWithoutTheExecutor() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.ping, executor: executor)

        XCTAssertTrue(response.ok)
        XCTAssertNil(executor.reprocessed)
    }

    // MARK: - Echo Suppression Is Three-Valued

    /// Absent means autodetect, which is not the same as false. A
    /// dispatcher that flattened the two would silently change how every
    /// reprocess treats speaker bleed.
    func testAbsentEchoSuppressionStaysAbsent() async {
        let executor = FakeExecutor()
        _ = await dispatch(AppCommandName.reprocessMeeting, ["meeting_id": "abc"], executor: executor)
        XCTAssertNil(executor.reprocessed?.suppressEcho)
    }

    func testEchoSuppressionIsCarriedWhenGiven() async {
        for (raw, expected) in [("1", true), ("true", true), ("0", false), ("false", false)] {
            let executor = FakeExecutor()
            _ = await dispatch(
                AppCommandName.reprocessMeeting,
                ["meeting_id": "abc", "suppress_echo": raw],
                executor: executor
            )
            XCTAssertEqual(executor.reprocessed?.suppressEcho, expected, "suppress_echo=\(raw)")
        }
    }

    // MARK: - Nothing Falls Through Silently

    func testUnknownCommandIsRefusedByName() async {
        let executor = FakeExecutor()
        let response = await dispatch("definitely_not_a_command", executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.unknownCommand.rawValue)
    }

    func testCommandWithoutMeetingIdIsRefused() async {
        for command in [AppCommandName.openMeeting, AppCommandName.reprocessMeeting, AppCommandName.exportMeeting] {
            let executor = FakeExecutor()
            let response = await dispatch(command, executor: executor)

            XCTAssertFalse(response.ok, command)
            XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue, command)
            XCTAssertNil(executor.reprocessed, command)
            XCTAssertNil(executor.exported, command)
            XCTAssertNil(executor.opened, command)
        }
    }

    /// Whitespace is not a meeting id. Passing it through would turn a typo into
    /// a "not found" from deep inside the app instead of a refusal at the edge.
    func testBlankMeetingIdIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.reprocessMeeting, ["meeting_id": "   "], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue)
        XCTAssertNil(executor.reprocessed)
    }

    func testTranscribeCarriesThePathAndRefusesWithoutOne() async {
        let executor = FakeExecutor()
        let refused = await dispatch(AppCommandName.transcribeFile, executor: executor)
        XCTAssertEqual(refused.reason, AppCommandResponse.Reason.invalidParameters.rawValue)
        XCTAssertNil(executor.transcribed)

        _ = await dispatch(AppCommandName.transcribeFile, ["path": "/tmp/voice.m4a"], executor: executor)
        XCTAssertEqual(executor.transcribed, "/tmp/voice.m4a")
    }

    func testImportWithoutPathIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.importFile, ["title": "Weekly"], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue)
        XCTAssertNil(executor.imported)
    }

    /// A refusal from the executor must arrive at the caller unchanged — this is
    /// the "meeting from the command does not exist" scenario.
    func testExecutorRefusalReachesTheCallerIntact() async {
        let executor = FakeExecutor()
        executor.answer = .failure("Встреча abc не найдена", reason: .notFound)

        let response = await dispatch(AppCommandName.reprocessMeeting, ["meeting_id": "abc"], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.notFound.rawValue)
        XCTAssertEqual(response.message, "Встреча abc не найдена")
    }

    // MARK: - Data Changes

    /// Absent means "leave alone", present and empty means "clear". A
    /// dispatcher that dropped empty values would make it impossible to erase a
    /// nickname, and one that invented absent keys would wipe fields nobody
    /// mentioned.
    func testSpeakerUpdateKeepsAbsentAndEmptyApart() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.updateSpeaker,
            ["speaker_id": "s1", "name": "Глеб", "nickname": ""],
            executor: executor
        )

        XCTAssertEqual(executor.speakerUpdate?.id, "s1")
        XCTAssertEqual(executor.speakerUpdate?.fields["name"], "Глеб")
        XCTAssertEqual(executor.speakerUpdate?.fields["nickname"], "")
        XCTAssertNil(executor.speakerUpdate?.fields["name_ru"])
        // The addressing parameter is not a field to write.
        XCTAssertNil(executor.speakerUpdate?.fields["speaker_id"])
    }

    func testSpeakerUpdateWithoutAnyFieldIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.updateSpeaker, ["speaker_id": "s1"], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue)
        XCTAssertNil(executor.speakerUpdate)
    }

    /// «Clear» is for the optional fields. A blank primary name left a speaker
    /// nobody could tell apart, and a blank title an unnamed meeting.
    func testBlankSpeakerNameIsRefused() async {
        for fields in [["name": ""], ["name_en": "  "], ["name": "Bob", "name_en": ""]] {
            let executor = FakeExecutor()
            let response = await dispatch(
                AppCommandName.updateSpeaker,
                fields.merging(["speaker_id": "s1"]) { $1 },
                executor: executor
            )

            XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue, "\(fields)")
            XCTAssertNil(executor.speakerUpdate, "\(fields)")
        }
    }

    func testBlankMeetingTitleIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(
            AppCommandName.updateMeeting,
            ["meeting_id": "m1", "title": " ", "description": ""],
            executor: executor
        )

        XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue)
        XCTAssertNil(executor.meetingUpdate)

        // An empty description is still how a description is erased.
        _ = await dispatch(AppCommandName.updateMeeting, ["meeting_id": "m1", "description": ""], executor: executor)
        XCTAssertEqual(executor.meetingUpdate?.fields, ["description": ""])
    }

    func testMergeSplitsTheSourceList() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.mergeSpeakers,
            ["target_id": "target", "source_ids": "a,b, c"],
            executor: executor
        )

        XCTAssertEqual(executor.merge?.targetId, "target")
        XCTAssertEqual(executor.merge?.sourceIds, ["a", "b", "c"])
    }

    /// Merging a speaker into itself deletes it — the source rows are removed
    /// once their segments are reassigned.
    func testMergeIntoItselfIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(
            AppCommandName.mergeSpeakers,
            ["target_id": "target", "source_ids": "a,target"],
            executor: executor
        )

        XCTAssertFalse(response.ok)
        XCTAssertNil(executor.merge)
    }

    func testMergeWithoutSourcesIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.mergeSpeakers, ["target_id": "target"], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertNil(executor.merge)
    }

    func testDetachSplitsTheMeetingList() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.detachMeetings,
            ["speaker_id": "clara", "meeting_ids": "m1,m2, m3"],
            executor: executor
        )

        XCTAssertEqual(executor.detach?.speakerId, "clara")
        XCTAssertEqual(executor.detach?.meetingIds, ["m1", "m2", "m3"])
    }

    func testDetachWithoutMeetingsIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.detachMeetings, ["speaker_id": "clara"], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertNil(executor.detach)
    }

    /// The real run writes to every series-less meeting: only an explicit "0"
    /// turns the dry run off, so "true" or "yes" cannot reach the database.
    func testApplySeriesRulesIsADryRunUnlessExplicitlyNot() async {
        let executor = FakeExecutor()
        for params in [[:], ["dry_run": "1"], ["dry_run": "true"], ["dry_run": "yes"]] {
            executor.applyRulesDryRun = nil
            _ = await dispatch(AppCommandName.applySeriesRules, params, executor: executor)
            XCTAssertEqual(executor.applyRulesDryRun, true, "\(params)")
        }
        _ = await dispatch(AppCommandName.applySeriesRules, ["dry_run": "0"], executor: executor)
        XCTAssertEqual(executor.applyRulesDryRun, false)
    }

    func testDeleteSpeakerNeedsAnId() async {
        let executor = FakeExecutor()
        let refused = await dispatch(AppCommandName.deleteSpeaker, [:], executor: executor)
        XCTAssertFalse(refused.ok)
        XCTAssertNil(executor.deletedSpeaker)

        _ = await dispatch(AppCommandName.deleteSpeaker, ["speaker_id": "clara"], executor: executor)
        XCTAssertEqual(executor.deletedSpeaker, "clara")
    }

    func testDeleteSplitsTheMeetingList() async {
        let executor = FakeExecutor()
        _ = await dispatch(AppCommandName.deleteMeetings, ["meeting_ids": "m1, m2,,m3"], executor: executor)

        XCTAssertEqual(executor.deleted, ["m1", "m2", "m3"])
    }

    func testDeleteWithoutMeetingsIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.deleteMeetings, ["meeting_ids": " , "], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue)
        XCTAssertNil(executor.deleted)
    }

    func testListenCommandsReachTheExecutor() async {
        for name in ListenCommands.names {
            let executor = FakeExecutor()
            _ = await dispatch(name, ["meeting_id": "m"], executor: executor)
            XCTAssertEqual(executor.listen?.command, name)
        }
    }

    func testSegmentUpdateParsesTheIdentifier() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.updateSegment,
            ["segment_id": "42", "speaker_id": "bob"],
            executor: executor
        )

        XCTAssertEqual(executor.segmentUpdate?.segmentId, 42)
        XCTAssertEqual(executor.segmentUpdate?.speakerId, "bob")
    }

    func testSegmentUpdateWithNonNumericIdIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(
            AppCommandName.updateSegment,
            ["segment_id": "forty-two", "speaker_id": "bob"],
            executor: executor
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.invalidParameters.rawValue)
        XCTAssertNil(executor.segmentUpdate)
    }

    func testMeetingUpdateCarriesOnlyNamedFields() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.updateMeeting,
            ["meeting_id": "m1", "title": "Новое имя", "nonsense": "x"],
            executor: executor
        )

        XCTAssertEqual(executor.meetingUpdate?.id, "m1")
        XCTAssertEqual(executor.meetingUpdate?.fields["title"], "Новое имя")
        XCTAssertNil(executor.meetingUpdate?.fields["nonsense"])
    }

    func testMeetingUpdateWithoutAnyFieldIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.updateMeeting, ["meeting_id": "m1"], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertNil(executor.meetingUpdate)
    }

    func testCreateSeriesCarriesTheName() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.createSeries,
            ["name": "Планёрка", "calendar_series_id": "cal-1"],
            executor: executor
        )

        XCTAssertEqual(executor.seriesCreate?.name, "Планёрка")
        XCTAssertEqual(executor.seriesCreate?.calendarSeriesId, "cal-1")
    }

    func testCreateSeriesWithoutNameIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.createSeries, ["name": "  "], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertNil(executor.seriesCreate)
    }

    func testUpdateSeriesKeepsOnlyKnownFields() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.updateSeries,
            ["series_id": "s1", "name": "121 Глеб", "auto_rule_pattern": "глеб", "hue": "12"],
            executor: executor
        )

        XCTAssertEqual(executor.seriesUpdate?.id, "s1")
        XCTAssertEqual(executor.seriesUpdate?.fields, ["name": "121 Глеб", "auto_rule_pattern": "глеб"])
    }

    func testUpdateSeriesWithoutFieldsIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.updateSeries, ["series_id": "s1"], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertNil(executor.seriesUpdate)
    }

    func testDeleteSeriesNeedsAnId() async {
        let executor = FakeExecutor()
        let refused = await dispatch(AppCommandName.deleteSeries, [:], executor: executor)
        XCTAssertFalse(refused.ok)
        XCTAssertNil(executor.seriesDelete)

        _ = await dispatch(AppCommandName.deleteSeries, ["series_id": "s1"], executor: executor)
        XCTAssertEqual(executor.seriesDelete, "s1")
    }

    func testMergeSeriesNeedsTwoDifferentIds() async {
        let executor = FakeExecutor()
        for params in [[:], ["source_id": "a"], ["target_id": "b"], ["source_id": "a", "target_id": "a"]] {
            let refused = await dispatch(AppCommandName.mergeSeries, params, executor: executor)
            XCTAssertFalse(refused.ok, "\(params)")
        }
        XCTAssertNil(executor.seriesMerge)

        _ = await dispatch(AppCommandName.mergeSeries, ["source_id": "a", "target_id": "b"], executor: executor)
        XCTAssertEqual(executor.seriesMerge?.sourceId, "a")
        XCTAssertEqual(executor.seriesMerge?.targetId, "b")
    }

    /// cli-meeting-edit: times go through `seconds()`, merge needs two
    /// different ids, undo names a known kind; nothing malformed reaches the app.
    func testMeetingEditParameters() async {
        let executor = FakeExecutor()
        let refused: [(String, [String: String])] = [
            (AppCommandName.splitMeeting, ["meeting_id": "m"]),
            (AppCommandName.splitMeeting, ["meeting_id": "m", "at": "-1"]),
            (AppCommandName.splitMeeting, ["meeting_id": "m", "at": "inf"]),
            (AppCommandName.trimMeeting, ["meeting_id": "m", "from": "1"]),
            (AppCommandName.mergeMeetings, ["first_id": "a"]),
            (AppCommandName.mergeMeetings, ["first_id": "a", "second_id": "a"]),
            (AppCommandName.undoMeetingEdit, ["meeting_id": "m", "kind": "delete"]),
            (AppCommandName.undoMeetingEdit, ["kind": "trim"]),
        ]
        for (command, params) in refused {
            let response = await dispatch(command, params, executor: executor)
            XCTAssertFalse(response.ok, "\(command) \(params)")
        }
        XCTAssertNil(executor.meetingEdit)

        _ = await dispatch(AppCommandName.splitMeeting, ["meeting_id": "m", "at": "61.5"], executor: executor)
        XCTAssertEqual(executor.meetingEdit?.values, ["61.5"])
        _ = await dispatch(AppCommandName.trimMeeting, ["meeting_id": "m", "from": "2", "to": "30"], executor: executor)
        XCTAssertEqual(executor.meetingEdit?.values, ["2.0", "30.0"])
        _ = await dispatch(AppCommandName.mergeMeetings, ["first_id": "a", "second_id": "b"], executor: executor)
        XCTAssertEqual(executor.meetingEdit?.id, "a")
        XCTAssertEqual(executor.meetingEdit?.values, ["b"])
        _ = await dispatch(AppCommandName.undoMeetingEdit, ["meeting_id": "m", "kind": "merge"], executor: executor)
        XCTAssertEqual(executor.meetingEdit?.values, ["merge"])
    }

    // MARK: - Exclusion marks

    func testMarkExcludedCarriesIntervalAndTrack() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.markExcluded,
            ["meeting_id": "m1", "from": "10.5", "to": "42", "track": "mic"],
            executor: executor
        )

        XCTAssertEqual(executor.markExcluded?.meetingId, "m1")
        XCTAssertEqual(executor.markExcluded?.from, 10.5)
        XCTAssertEqual(executor.markExcluded?.to, 42)
        XCTAssertEqual(executor.markExcluded?.track, "mic")
    }

    func testMarkExcludedWithInvertedIntervalIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(
            AppCommandName.markExcluded,
            ["meeting_id": "m1", "from": "42", "to": "10"],
            executor: executor
        )

        XCTAssertFalse(response.ok)
        XCTAssertNil(executor.markExcluded)
    }

    /// `Double("inf")` and `Double("1e19")` both parse. Stored in a mark, the
    /// first breaks the JSON listing of the meeting's marks and the second
    /// traps `Int(seconds)` in the timestamp formatter — `vedivox marks` then dies
    /// on that meeting for good.
    func testMarkTimesMustBeOnTheClock() async {
        let intervals = [("0", "inf"), ("-inf", "10"), ("nan", "10"), ("-5", "10"), ("0", "1e19")]
        for (from, to) in intervals {
            for command in [AppCommandName.markExcluded, AppCommandName.unmark] {
                let executor = FakeExecutor()
                let response = await dispatch(command, ["meeting_id": "m1", "from": from, "to": to], executor: executor)

                XCTAssertEqual(
                    response.reason, AppCommandResponse.Reason.invalidParameters.rawValue, "\(command) \(from)…\(to)"
                )
                XCTAssertNil(executor.markExcluded)
                XCTAssertNil(executor.unmark)
            }
        }
    }

    func testMarkExcludedWithoutTimesIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.markExcluded, ["meeting_id": "m1"], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertNil(executor.markExcluded)
    }

    func testUnmarkPrefersMarkId() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.unmark,
            ["meeting_id": "m1", "mark_id": "7"],
            executor: executor
        )

        XCTAssertEqual(executor.unmark?.markId, 7)
        XCTAssertNil(executor.unmark?.from)
    }

    func testUnmarkAcceptsRangeForm() async {
        let executor = FakeExecutor()
        _ = await dispatch(
            AppCommandName.unmark,
            ["meeting_id": "m1", "from": "5", "to": "9", "track": "system"],
            executor: executor
        )

        XCTAssertNil(executor.unmark?.markId)
        XCTAssertEqual(executor.unmark?.from, 5)
        XCTAssertEqual(executor.unmark?.to, 9)
        XCTAssertEqual(executor.unmark?.track, "system")
    }

    func testUnmarkWithNeitherFormIsRefused() async {
        let executor = FakeExecutor()
        let response = await dispatch(AppCommandName.unmark, ["meeting_id": "m1"], executor: executor)

        XCTAssertFalse(response.ok)
        XCTAssertNil(executor.unmark)
    }
}
