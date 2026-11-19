import ArgumentParser
import Foundation
import VedivoxMCPLib

/// `vedivox live` — the text of the meeting being recorded, read from the running app.
extension CLIActionCore {
    /// Never launches the app: with nothing serving there is nothing recording.
    static func live(last: String?, json: Bool, precise: Bool = false) throws -> String {
        var lastSeconds: Double?
        if let last {
            guard let seconds = LiveTranscript.seconds(fromDuration: last) else {
                throw CLIFailure(code: 64, message: "--last takes a number with a unit: 90s, 5m, 1h")
            }
            lastSeconds = seconds
        }
        guard try CLIRuntime.isAppServing() else {
            throw CLIFailure.refusal("Vedivox is not running; nothing is recording")
        }
        let response = try CLIRuntime.sendCommand(LiveTranscript.request(lastSeconds: lastSeconds, precise: precise))
        if response.reason == "unknown_command" {
            throw CLIFailure.refusal("this Vedivox build has no live transcript; update the app")
        }
        if let failure = cliFailure(from: response) { throw failure }
        do {
            let document = try LiveTranscript.document(from: response)
            return json ? try cliJSON(document) : LiveTranscript.render(document)
        } catch LiveTranscript.Failure.malformed(let message) {
            throw CLIFailure.unavailable(message)
        }
    }
}

struct Live: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live",
        abstract: "Live text of the meeting being recorded, with who said what: all of it so far, or the last minutes. Preliminary; fails when nothing is recording."
    )

    @Option(help: "Only the last stretch of the recording: 90s, 5m, 1h. Omit for everything so far.")
    var last: String?

    @Flag(help: "Machine output: {\"meeting_id\", \"state\", \"elapsed\", \"dropped_seconds\", \"turns\": [{\"speaker\": {\"kind\": me|known|unknown, \"name\", \"confidence\"}, \"track\", \"from\", \"to\", \"text\"}]}.")
    var json = false

    @Flag(help: "Refine the last minutes first (up to 10) with the pipeline the final transcript uses: better text, names of recognised speakers. Takes a few seconds.")
    var precise = false

    func run() throws { try executeCore { try CLIActionCore.live(last: last, json: json, precise: precise) } }
}
