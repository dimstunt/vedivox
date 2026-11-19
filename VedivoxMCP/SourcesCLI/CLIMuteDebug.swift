import ArgumentParser
import Foundation
import VedivoxMCPLib

/// `vedivox mute-debug` — what Vedivox reads as the call's mute state right now, with
/// the Teams accessibility tree around the mic button and the
/// Telemost trees (telemost-support D4). Runs in the
/// app, the one process with the Accessibility permission.
extension CLIActionCore {
    /// Never launches the app: a fresh Vedivox would answer before it ever polled.
    static func muteDebug() throws -> String {
        guard try CLIRuntime.isAppServing() else {
            throw CLIFailure.unavailable("Vedivox is not running; start it first — the check runs inside the app")
        }
        let response = try CLIRuntime.sendLongCommand(AppCommandRequest(command: AppCommandName.diagnoseMute))
        if let failure = cliFailure(from: response) { throw failure }
        return response.message
    }
}

struct MuteDebug: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mute-debug",
        abstract: "Diagnostics: the mute state Vedivox reads from Zoom and Teams now, the Teams accessibility tree around the mic button, and the Yandex Telemost trees.",
        discussion: "Run it during a Teams or Telemost call, once muted and once unmuted, and attach the output when mute is misread. Telemost has no mute reader yet: its output is what one would be written from; in a browser the call tab must be the active tab of its window."
    )

    func run() throws { try executeCore { try CLIActionCore.muteDebug() } }
}
