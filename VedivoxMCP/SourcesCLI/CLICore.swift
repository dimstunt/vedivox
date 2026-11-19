import Foundation
import VedivoxMCPLib

/// A command outcome the shell can act on: exit code + message for stderr.
///
/// The code table is the CLI's contract (design § решение 4):
/// 0 done, 1 refusal, 2 object not found, 3 data unavailable, 64 usage.
package struct CLIFailure: Error, Equatable {
    package var code: Int32
    package var message: String
    /// Printed to stdout before exiting: a machine report that matters most on failure.
    package var output: String?

    package init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    package static func refusal(_ message: String) -> CLIFailure { .init(code: 1, message: message) }
    package static func notFound(_ message: String) -> CLIFailure { .init(code: 2, message: message) }
    package static func unavailable(_ message: String) -> CLIFailure { .init(code: 3, message: message) }
}

/// Maps every lower-layer error onto the exit-code table. One place, so a new
/// error kind cannot silently land on the wrong code.
package func cliFailure(from error: Error) -> CLIFailure {
    switch error {
    case let failure as CLIFailure:
        return failure
    case let mcp as MCPError:
        switch mcp {
        case .databaseNotFound(let path):
            return .unavailable("database not found at \(path)")
        case .meetingNotFound(let id):
            return .notFound("meeting \(id) not found")
        case .invalidArgument(let name, let reason):
            return CLIFailure(code: 64, message: "invalid \(name): \(reason)")
        }
    case let app as AppCommandError:
        // The app is not answering or unreachable — data/service unavailable.
        return .unavailable(app.description)
    default:
        // Database open/read errors and everything else that means "could not
        // get the data": a monitoring loop must stop, not see an empty list.
        return .unavailable("\(error)")
    }
}

/// Maps an app command response onto the code table. `ok` means the action ran;
/// the reason distinguishes "no such object" and "app not reachable" refusals.
package func cliFailure(from response: AppCommandResponse) -> CLIFailure? {
    guard !response.ok else { return nil }
    let message = response.reason.map { "\(response.message) [\($0)]" } ?? response.message
    switch response.reason {
    case "not_found":
        return .notFound(message)
    case "unreachable", "timed_out":
        return .unavailable(message)
    case "invalid_parameters":
        // The app's word for what the CLI itself reports as 64.
        return CLIFailure(code: 64, message: message)
    default:
        return .refusal(message)
    }
}

/// Whether a Vedivox instance is currently serving the data directory. Injectable
/// so tests can simulate a live or dead app (same pattern as AppCommandDispatch).
package enum CLIRuntime {
    package nonisolated(unsafe) static var isAppServing: @Sendable () throws -> Bool = {
        try AppCommandClient.isServed()
    }

    /// Sends an action command to the app (launches it when needed).
    package nonisolated(unsafe) static var sendCommand: @Sendable (AppCommandRequest) throws -> AppCommandResponse = {
        try AppCommandDispatch.run($0)
    }

    /// Same, without launching the app and with a day to answer: for a command
    /// whose run is measured in hours (`vedivox audio compact`).
    package nonisolated(unsafe) static var sendLongCommand: @Sendable (AppCommandRequest) throws -> AppCommandResponse = {
        try AppCommandClient.send($0, timeout: 86400)
    }
}

/// JSON encoder for machine output: stable key order, readable URLs.
package var cliJSONEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
}

package func cliJSON(_ value: some Encodable) throws -> String {
    let data = try cliJSONEncoder.encode(value)
    return String(bytes: data, encoding: .utf8) ?? "null"
}

// MARK: - Meeting resolution by id prefix

/// Resolves a meeting by the start of its id (design § решение 8).
///
/// - 0 matches → code 2, distinguishable from other refusals;
/// - 1 match → the meeting;
/// - several → code 1, listing the candidates; nothing is acted on.
/// Series are addressed like meetings: the full id or an unambiguous prefix.
package func resolveSeries(idPrefix: String, db: DatabaseReader) throws -> MeetingSeries {
    guard !idPrefix.isEmpty else {
        throw CLIFailure(code: 64, message: "empty series id")
    }
    let matches = try db.listSeries().map(\.series)
        .filter { $0.id.uppercased().hasPrefix(idPrefix.uppercased()) }
    switch matches.count {
    case 1:
        return matches[0]
    case 0:
        throw CLIFailure.notFound("no series with id starting with \(idPrefix)")
    default:
        let listing = matches.map { "  \($0.id)  \($0.name)" }.joined(separator: "\n")
        throw CLIFailure.refusal(
            "id prefix \(idPrefix) is ambiguous, matches \(matches.count) series:\n\(listing)"
        )
    }
}

package func resolveMeeting(idPrefix: String, db: DatabaseReader) throws -> Meeting {
    guard !idPrefix.isEmpty else {
        throw CLIFailure(code: 64, message: "empty meeting id")
    }
    let matches = try db.meetings(idPrefix: idPrefix)
    switch matches.count {
    case 1:
        return matches[0]
    case 0:
        throw CLIFailure.notFound("no meeting with id starting with \(idPrefix)")
    default:
        let listing = matches
            .map { "  \($0.id)  \($0.title)" }
            .joined(separator: "\n")
        throw CLIFailure.refusal(
            "id prefix \(idPrefix) is ambiguous, matches \(matches.count) meetings:\n\(listing)"
        )
    }
}
