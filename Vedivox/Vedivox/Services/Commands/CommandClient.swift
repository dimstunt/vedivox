import Darwin
import Foundation

/// Sends a command to the instance that owns a data directory and waits for the
/// outcome.
///
/// Blocking on purpose: the caller reports what happened, and it cannot do that
/// before it knows. The previous arrangement — hand a URL to the system and
/// return its exit code — is precisely how an unexecuted command came back as
/// success on 2026-08-14.
enum CommandClient {
    /// Whether an instance is currently serving this data directory.
    static func isServed(directory: URL) -> Bool {
        CommandSocket.isAlive(at: CommandSocket.url(in: directory).path)
    }

    /// Sends `request` and returns the outcome reported by the app.
    ///
    /// Throws only when the command could not be delivered or the answer could
    /// not be read. A command that was executed and failed comes back as a
    /// response with `ok == false`, not as a thrown error — the two are
    /// genuinely different outcomes and callers act on them differently.
    static func send(
        _ request: AppCommandRequest,
        to directory: URL,
        timeout: TimeInterval = 120
    ) throws -> AppCommandResponse {
        let path = CommandSocket.url(in: directory).path

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CommandSocketError.socketFailed(errno: errno) }
        defer { Darwin.close(descriptor) }

        CommandSocket.setTimeout(descriptor, seconds: timeout)
        CommandSocket.suppressBrokenPipeSignal(descriptor)

        var address = try CommandSocket.address(for: path)
        let connected = CommandSocket.withAddress(&address) { pointer, length in
            Darwin.connect(descriptor, pointer, length)
        }
        guard connected == 0 else {
            throw CommandSocketError.connectFailed(path: path, errno: errno)
        }

        try CommandSocket.writeAll(descriptor, try CommandSocket.encode(request))

        // Tell the peer no more request is coming, so it can act without
        // waiting on a read that will never complete.
        shutdown(descriptor, SHUT_WR)

        let data = try CommandSocket.readMessage(descriptor)
        return try JSONDecoder().decode(AppCommandResponse.self, from: data)
    }
}
