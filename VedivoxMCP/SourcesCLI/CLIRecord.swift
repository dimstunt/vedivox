import ArgumentParser
import Foundation
import VedivoxMCPLib

/// Machine output of `vedivox record`; `system_audio` only for start.
struct RecordResult: Encodable {
    let meetingId: String
    let systemAudio: Bool?

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case systemAudio = "system_audio"
    }
}

/// `vedivox record start|stop` — recording control in the running app.
extension CLIActionCore {
    static func recordStart(title: String?, json: Bool) throws -> String {
        var params: [String: String] = [:]
        if let title { params["title"] = title }
        return try sendRecord(AppCommandRequest(command: AppCommandName.startRecording, params: params), json: json)
    }

    /// Never launches the app: with nothing serving there is nothing to stop.
    static func recordStop(json: Bool) throws -> String {
        guard try CLIRuntime.isAppServing() else {
            throw CLIFailure.refusal("Vedivox is not running; nothing is recording")
        }
        return try sendRecord(AppCommandRequest(command: AppCommandName.stopRecording), json: json)
    }

    private static func sendRecord(_ request: AppCommandRequest, json: Bool) throws -> String {
        let response = try CLIRuntime.sendCommand(request)
        if let failure = cliFailure(from: response) { throw failure }
        guard json else { return response.message }
        guard let id = response.data?["meeting_id"] else {
            throw CLIFailure.unavailable("the app did not report a meeting id (older Vedivox build?)")
        }
        return try cliJSON(RecordResult(meetingId: id, systemAudio: response.data?["system_audio"].map { $0 == "1" }))
    }
}

struct RecordCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start or stop a meeting recording in the app.",
        subcommands: [Start.self, Stop.self]
    )

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start recording (launches Vedivox if needed); prints the new meeting id, flags a microphone-only recording."
        )
        @Option(help: "Meeting title. Omit to take title, calendar event and series from the detected meeting, as the menu does.")
        var title: String?
        @Flag(help: "Machine output: {\"meeting_id\", \"system_audio\"}.") var json = false
        func run() throws { try executeCore { try CLIActionCore.recordStart(title: title, json: json) } }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop the running recording; the meeting goes to processing (not awaited, see `vedivox status`)."
        )
        @Flag(help: "Machine output: {\"meeting_id\"}.") var json = false
        func run() throws { try executeCore { try CLIActionCore.recordStop(json: json) } }
    }
}
