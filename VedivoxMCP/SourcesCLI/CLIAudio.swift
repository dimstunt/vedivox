import ArgumentParser
import Foundation
import VedivoxMCPLib

/// Machine output of `vedivox audio compact`.
struct CompactResult: Encodable {
    let dryRun: Bool
    let tracksCompacted: Int
    let tracksAlreadyCompact: Int
    let tracksFailed: Int
    let meetingsBusy: Int
    let bytesBefore: Int64
    let bytesAfter: Int64
    let bytesFreed: Int64
    let failed: [String]
    let anomalies: [String]

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case tracksCompacted = "tracks_compacted"
        case tracksAlreadyCompact = "tracks_already_compact"
        case tracksFailed = "tracks_failed"
        case meetingsBusy = "meetings_busy"
        case bytesBefore = "bytes_before"
        case bytesAfter = "bytes_after"
        case bytesFreed = "bytes_freed"
        case failed, anomalies
    }

    init(_ data: [String: String]) {
        let int = { Int(data[$0] ?? "") ?? 0 }
        let int64 = { Int64(data[$0] ?? "") ?? 0 }
        let list = { (data[$0] ?? "").split(separator: "\n").map(String.init) }
        dryRun = data["dry_run"] == "1"
        tracksCompacted = int("tracks_compacted")
        tracksAlreadyCompact = int("tracks_already_compact")
        tracksFailed = int("tracks_failed")
        meetingsBusy = int("meetings_busy")
        bytesBefore = int64("bytes_before")
        bytesAfter = int64("bytes_after")
        bytesFreed = int64("bytes_freed")
        failed = list("failed")
        anomalies = list("anomalies")
    }
}

extension CLIActionCore {
    /// Never launches the app: the archive is the app's, and a run without it
    /// would race whatever it starts doing on launch.
    static func audioCompact(dryRun: Bool, json: Bool) throws -> String {
        guard try CLIRuntime.isAppServing() else {
            throw CLIFailure.unavailable("Vedivox is not running; start it first — compact runs inside the app")
        }
        let request = AppCommandRequest(command: AppCommandName.compactAudio, params: ["dry_run": dryRun ? "1" : "0"])
        let response = try CLIRuntime.sendLongCommand(request)
        if var failure = cliFailure(from: response) {
            // A partial run's report is what a script needs most; a refusal has none.
            if json, let data = response.data { failure.output = try cliJSON(CompactResult(data)) }
            throw failure
        }
        guard json else { return response.message }
        return try cliJSON(CompactResult(response.data ?? [:]))
    }
}

struct AudioCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Stored audio of meetings.",
        subcommands: [Compact.self]
    )

    struct Compact: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compact",
            abstract: "Re-encode older tracks to the compact storage format (64 kbps, 24 kHz). Lossy and irreversible: run --dry-run first.",
            discussion: """
            Runs in the app, one meeting at a time from the oldest; each copy is checked against \
            the original before it replaces it. Stops after the current track if a recording or a dictation starts; \
            running again continues. Exit 0 done, 1 some tracks failed or the run stopped, 3 Vedivox is not running.
            """
        )
        @Flag(help: "Only count the tracks and the space to free; change nothing.") var dryRun = false
        @Flag(help: "Machine output (snake_case keys).") var json = false
        func run() throws { try executeCore { try CLIActionCore.audioCompact(dryRun: dryRun, json: json) } }
    }
}
