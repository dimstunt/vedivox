import Foundation

/// What a command can ask the running app to do.
///
/// Exists so the parameter contract lives in the UI-free core and can be tested
/// without an app host: `AppState` is the only real implementation, but it is
/// compiled into the app target alone, and an untested dispatch layer is where
/// a silently dropped command hides.
@MainActor
protocol CommandExecutor: AnyObject {
    func commandOpenMeeting(id: String, seekTime: Double?) async -> AppCommandResponse
    func commandReprocessMeeting(id: String, suppressEcho: Bool?) async -> AppCommandResponse
    func commandExportMeeting(id: String) async -> AppCommandResponse
    func commandImportFile(path: String, title: String?, date: String?) async -> AppCommandResponse
    /// Answers with the segments in `data["segments"]` (a JSON array); writes nothing.
    func commandTranscribeFile(path: String) async -> AppCommandResponse

    /// Fields are optional twice over: absent means "leave alone", present and
    /// empty means "clear". Collapsing the two would make it impossible to
    /// erase a nickname.
    func commandUpdateSpeaker(id: String, fields: [String: String]) async -> AppCommandResponse
    func commandMergeSpeakers(targetId: String, sourceIds: [String]) async -> AppCommandResponse
    func commandDetachMeetings(speakerId: String, meetingIds: [String]) async -> AppCommandResponse
    func commandDeleteSpeaker(id: String) async -> AppCommandResponse
    func commandUpdateSegment(segmentId: Int64, speakerId: String) async -> AppCommandResponse
    func commandUpdateMeeting(id: String, fields: [String: String]) async -> AppCommandResponse
    /// All or nothing: an unknown or busy meeting refuses the whole batch.
    func commandDeleteMeetings(ids: [String]) async -> AppCommandResponse
    /// Split, trim, merge and their undo — the window's paths (cli-meeting-edit).
    /// Times are seconds on the meeting's current timeline.
    func commandSplitMeeting(id: String, at time: Double) async -> AppCommandResponse
    func commandTrimMeeting(id: String, from: Double, to: Double) async -> AppCommandResponse
    func commandMergeMeetings(firstId: String, secondId: String) async -> AppCommandResponse
    /// `kind` is split, trim or merge.
    func commandUndoMeetingEdit(id: String, kind: String) async -> AppCommandResponse
    func commandCreateSeries(name: String, calendarSeriesId: String?) async -> AppCommandResponse
    /// Same optional-twice-over contract as speakers and meetings.
    func commandUpdateSeries(id: String, fields: [String: String]) async -> AppCommandResponse
    func commandDeleteSeries(id: String) async -> AppCommandResponse
    /// The source's meetings move to the target, then the source is deleted.
    func commandMergeSeries(sourceId: String, targetId: String) async -> AppCommandResponse
    /// `dryRun` answers with what would be assigned and writes nothing.
    func commandApplySeriesRules(dryRun: Bool) async -> AppCommandResponse

    /// Exclusion marks (transcript-exclusion-marks). `track` arrives as the
    /// raw wire string; the executor validates it against known tracks.
    func commandMarkExcluded(meetingId: String, from: Double, to: Double, track: String?) async -> AppCommandResponse
    /// Either `markId` (delete that mark) or `from`/`to` (lay an included
    /// interval over the range) — the dispatcher guarantees exactly one form.
    func commandUnmark(meetingId: String, markId: Int64?, from: Double?, to: Double?, track: String?) async -> AppCommandResponse

    /// Recording control. Start answers once both captures are up (or the
    /// start failed); stop answers once the audio session has stopped.
    func commandStartRecording(title: String?) async -> AppCommandResponse
    func commandStopRecording() async -> AppCommandResponse
    /// What was said in the last `last` seconds of the running recording, or
    /// all of it when nil. Answers with the document of `LiveTranscriptCommand`.
    /// `precise`: first refine that stretch with a pass of the regular
    /// pipeline, and answer when it is done.
    func commandLiveTranscript(last: Double?, precise: Bool) async -> AppCommandResponse

    /// Re-encodes stored tracks to the storage preset; `dryRun` only counts.
    func commandCompactAudio(dryRun: Bool) async -> AppCommandResponse

    /// The listen-queue commands (`ListenCommands.names`): parsed and run by
    /// `ListenCommands.handle`; the executor adds what only the app can do
    /// (refreshing open views).
    func commandListen(_ request: AppCommandRequest) async -> AppCommandResponse
}

/// Turns a wire request into a call on the executor.
///
/// Every path returns a response. There is deliberately no way to fall through
/// without answering — that fall-through is the defect this change exists to
/// remove.
enum CommandDispatcher {
    /// The socket trusts any process of this user (SECURITY.md), so a recording
    /// it started is announced: the user learns the mic is on even if they did
    /// not ask for it. The hotkey, menu and auto start do not come through here.
    static func announcesRecordingStart(_ request: AppCommandRequest, _ response: AppCommandResponse) -> Bool {
        request.command == AppCommandName.startRecording && response.ok
    }

    @MainActor
    static func dispatch(
        _ request: AppCommandRequest,
        to executor: any CommandExecutor
    ) async -> AppCommandResponse {
        switch request.command {
        case AppCommandName.ping:
            return .success("Vedivox is here")

        case AppCommandName.openMeeting:
            guard let id = requiredMeetingId(request) else { return missingMeetingId(request) }
            let seekTime = seconds(request.params["t"])
            return await executor.commandOpenMeeting(id: id, seekTime: seekTime)

        case AppCommandName.reprocessMeeting:
            guard let id = requiredMeetingId(request) else { return missingMeetingId(request) }
            // Absent means autodetect — which is not the same as
            // false, so it must survive the trip as absent.
            let suppressEcho = request.params["suppress_echo"].map { $0 == "1" || $0 == "true" }
            return await executor.commandReprocessMeeting(id: id, suppressEcho: suppressEcho)

        case AppCommandName.exportMeeting:
            guard let id = requiredMeetingId(request) else { return missingMeetingId(request) }
            return await executor.commandExportMeeting(id: id)

        case AppCommandName.importFile:
            guard let path = request.params["path"]?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
                return .failure("\(request.command) is missing the path parameter", reason: .invalidParameters)
            }
            return await executor.commandImportFile(
                path: path,
                title: nonEmpty(request.params["title"]),
                date: nonEmpty(request.params["date"])
            )

        case AppCommandName.transcribeFile:
            guard let path = nonEmpty(request.params["path"]) else {
                return .failure("\(request.command) is missing the path parameter", reason: .invalidParameters)
            }
            return await executor.commandTranscribeFile(path: path)

        case AppCommandName.updateSpeaker:
            guard let id = nonEmpty(request.params["speaker_id"]) else {
                return .failure("\(request.command) is missing the speaker_id parameter", reason: .invalidParameters)
            }
            let fields = request.params.filter { speakerFields.contains($0.key) }
            guard !fields.isEmpty else {
                return .failure(
                    "\(request.command) names no field to change: \(speakerFields.sorted().joined(separator: ", "))",
                    reason: .invalidParameters
                )
            }
            // «Clear» is for the optional fields; the name is the label on
            // every segment and must stay tellable.
            if ["name", "name_en"].contains(where: { key in fields[key].map { nonEmpty($0) == nil } ?? false }) {
                return .failure("The speaker name cannot be empty", reason: .invalidParameters)
            }
            return await executor.commandUpdateSpeaker(id: id, fields: fields)

        case AppCommandName.mergeSpeakers:
            guard let targetId = nonEmpty(request.params["target_id"]) else {
                return .failure("\(request.command) is missing the target_id parameter", reason: .invalidParameters)
            }
            let sourceIds = (request.params["source_ids"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !sourceIds.isEmpty else {
                return .failure("\(request.command) is missing source_ids", reason: .invalidParameters)
            }
            guard !sourceIds.contains(targetId) else {
                return .failure("target_id must not be one of source_ids", reason: .invalidParameters)
            }
            return await executor.commandMergeSpeakers(targetId: targetId, sourceIds: sourceIds)

        case AppCommandName.detachMeetings:
            guard let speakerId = nonEmpty(request.params["speaker_id"]) else {
                return .failure("\(request.command) is missing the speaker_id parameter", reason: .invalidParameters)
            }
            let meetingIds = (request.params["meeting_ids"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !meetingIds.isEmpty else {
                return .failure("\(request.command) is missing meeting_ids", reason: .invalidParameters)
            }
            return await executor.commandDetachMeetings(speakerId: speakerId, meetingIds: meetingIds)

        case AppCommandName.deleteSpeaker:
            guard let speakerId = nonEmpty(request.params["speaker_id"]) else {
                return .failure("\(request.command) is missing the speaker_id parameter", reason: .invalidParameters)
            }
            return await executor.commandDeleteSpeaker(id: speakerId)

        case AppCommandName.updateSegment:
            guard let raw = nonEmpty(request.params["segment_id"]), let segmentId = Int64(raw) else {
                return .failure("\(request.command) needs an integer segment_id", reason: .invalidParameters)
            }
            guard let speakerId = nonEmpty(request.params["speaker_id"]) else {
                return .failure("\(request.command) is missing the speaker_id parameter", reason: .invalidParameters)
            }
            return await executor.commandUpdateSegment(segmentId: segmentId, speakerId: speakerId)

        case AppCommandName.updateMeeting:
            guard let id = requiredMeetingId(request) else { return missingMeetingId(request) }
            let fields = request.params.filter { meetingFields.contains($0.key) }
            guard !fields.isEmpty else {
                return .failure(
                    "\(request.command) names no field to change: \(meetingFields.sorted().joined(separator: ", "))",
                    reason: .invalidParameters
                )
            }
            if let title = fields["title"], nonEmpty(title) == nil {
                return .failure("The meeting title cannot be empty", reason: .invalidParameters)
            }
            return await executor.commandUpdateMeeting(id: id, fields: fields)

        case AppCommandName.deleteMeetings:
            let ids = (request.params["meeting_ids"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !ids.isEmpty else {
                return .failure("\(request.command) is missing meeting_ids", reason: .invalidParameters)
            }
            return await executor.commandDeleteMeetings(ids: ids)

        case AppCommandName.splitMeeting:
            guard let id = requiredMeetingId(request) else { return missingMeetingId(request) }
            guard let at = seconds(request.params["at"]) else {
                return .failure("at must be a number of seconds, 0 or more", reason: .invalidParameters)
            }
            return await executor.commandSplitMeeting(id: id, at: at)

        case AppCommandName.trimMeeting:
            guard let id = requiredMeetingId(request) else { return missingMeetingId(request) }
            guard let from = seconds(request.params["from"]), let to = seconds(request.params["to"]) else {
                return .failure("from and to must be numbers of seconds, 0 or more", reason: .invalidParameters)
            }
            return await executor.commandTrimMeeting(id: id, from: from, to: to)

        case AppCommandName.mergeMeetings:
            guard let first = nonEmpty(request.params["first_id"]), let second = nonEmpty(request.params["second_id"]),
                  first != second else {
                return .failure("\(request.command) needs two different meetings: first_id and second_id",
                                reason: .invalidParameters)
            }
            return await executor.commandMergeMeetings(firstId: first, secondId: second)

        case AppCommandName.undoMeetingEdit:
            guard let id = requiredMeetingId(request) else { return missingMeetingId(request) }
            guard let kind = nonEmpty(request.params["kind"]), ["split", "trim", "merge"].contains(kind) else {
                return .failure("kind must be split, trim or merge", reason: .invalidParameters)
            }
            return await executor.commandUndoMeetingEdit(id: id, kind: kind)

        case AppCommandName.markExcluded:
            guard let id = requiredMeetingId(request) else { return missingMeetingId(request) }
            guard let from = seconds(request.params["from"]), let to = seconds(request.params["to"]) else {
                return .failure("\(request.command) needs from and to in seconds, 0 or more", reason: .invalidParameters)
            }
            guard to > from else {
                return .failure("to must be greater than from", reason: .invalidParameters)
            }
            return await executor.commandMarkExcluded(
                meetingId: id, from: from, to: to, track: nonEmpty(request.params["track"])
            )

        case AppCommandName.unmark:
            guard let id = requiredMeetingId(request) else { return missingMeetingId(request) }
            if let rawMarkId = nonEmpty(request.params["mark_id"]) {
                guard let markId = Int64(rawMarkId) else {
                    return .failure("mark_id must be an integer", reason: .invalidParameters)
                }
                return await executor.commandUnmark(
                    meetingId: id, markId: markId, from: nil, to: nil, track: nil
                )
            }
            guard let from = seconds(request.params["from"]), let to = seconds(request.params["to"]) else {
                return .failure(
                    "\(request.command) needs either mark_id or from and to in seconds, 0 or more",
                    reason: .invalidParameters
                )
            }
            guard to > from else {
                return .failure("to must be greater than from", reason: .invalidParameters)
            }
            return await executor.commandUnmark(
                meetingId: id, markId: nil, from: from, to: to, track: nonEmpty(request.params["track"])
            )

        case AppCommandName.createSeries:
            guard let name = nonEmpty(request.params["name"]) else {
                return .failure("\(request.command) is missing the name parameter", reason: .invalidParameters)
            }
            return await executor.commandCreateSeries(
                name: name,
                calendarSeriesId: nonEmpty(request.params["calendar_series_id"])
            )

        case AppCommandName.updateSeries:
            guard let id = nonEmpty(request.params["series_id"]) else {
                return .failure("\(request.command) is missing the series_id parameter", reason: .invalidParameters)
            }
            let fields = request.params.filter { seriesFields.contains($0.key) }
            guard !fields.isEmpty else {
                return .failure(
                    "\(request.command) names no field to change: \(seriesFields.sorted().joined(separator: ", "))",
                    reason: .invalidParameters
                )
            }
            return await executor.commandUpdateSeries(id: id, fields: fields)

        case AppCommandName.deleteSeries:
            guard let id = nonEmpty(request.params["series_id"]) else {
                return .failure("\(request.command) is missing the series_id parameter", reason: .invalidParameters)
            }
            return await executor.commandDeleteSeries(id: id)

        case AppCommandName.mergeSeries:
            guard let source = nonEmpty(request.params["source_id"]),
                  let target = nonEmpty(request.params["target_id"]) else {
                return .failure(
                    "\(request.command) needs the source_id and target_id parameters", reason: .invalidParameters
                )
            }
            guard source != target else {
                return .failure("source_id and target_id are the same series", reason: .invalidParameters)
            }
            return await executor.commandMergeSeries(sourceId: source, targetId: target)

        case AppCommandName.applySeriesRules:
            // Same rule as compact_audio: only an explicit "0" writes, so a
            // garbled flag ("true", "yes") stays a dry run.
            return await executor.commandApplySeriesRules(dryRun: request.params["dry_run"] != "0")

        case AppCommandName.startRecording:
            return await executor.commandStartRecording(title: nonEmpty(request.params["title"]))

        case AppCommandName.stopRecording:
            return await executor.commandStopRecording()

        case AppCommandName.liveTranscript:
            // Absent means the whole recording; a garbled window must not
            // quietly turn into that.
            // Only an explicit yes waits for a pass: a garbled flag must not
            // turn a quick look into seconds of waiting.
            let precise = request.params["precise"] == "1"
            guard let raw = nonEmpty(request.params["last"]) else {
                return await executor.commandLiveTranscript(last: nil, precise: precise)
            }
            guard let last = seconds(raw) else {
                return .failure("last must be a number of seconds, 0 or more", reason: .invalidParameters)
            }
            return await executor.commandLiveTranscript(last: last, precise: precise)

        case AppCommandName.compactAudio:
            // Anything but an explicit "no" is a dry run: the real run is the
            // irreversible one, so a garbled flag must not reach it.
            let dryRun = request.params["dry_run"] != "0"
            return await executor.commandCompactAudio(dryRun: dryRun)

        case AppCommandName.diagnoseMute:
            // Off the main actor: the walk is thousands of AX round trips.
            return .success(await Task.detached(priority: .userInitiated) { MuteDiagnostics.report() }.value)

        case let name where ListenCommands.names.contains(name):
            return await executor.commandListen(request)

        default:
            return .failure("Unknown command: \(request.command)", reason: .unknownCommand)
        }
    }

    // MARK: - Parameters

    /// Editable fields, listed so an unrecognised key is ignored rather than
    /// silently treated as a field the app happens not to have.
    static let speakerFields: Set<String> = ["name", "nickname", "name_ru", "name_en", "is_me", "confirmed"]
    static let meetingFields: Set<String> = ["title", "description", "series_id"]
    static let seriesFields: Set<String> = ["name", "calendar_series_id", "auto_rule_pattern"]

    private static func requiredMeetingId(_ request: AppCommandRequest) -> String? {
        nonEmpty(request.params["meeting_id"])
    }

    private static func missingMeetingId(_ request: AppCommandRequest) -> AppCommandResponse {
        .failure("\(request.command) is missing the meeting_id parameter", reason: .invalidParameters)
    }

    /// A time on a meeting's clock. `Double("inf")`, `"nan"` and `"1e19"` all
    /// parse; in a stored mark the first breaks JSON output and the last traps
    /// `Int(seconds)` wherever the time is printed.
    private static func seconds(_ raw: String?) -> Double? {
        guard let value = raw.flatMap(Double.init), value >= 0, value < 1e9 else { return nil }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
