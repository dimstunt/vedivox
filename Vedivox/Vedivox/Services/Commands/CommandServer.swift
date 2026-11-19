import Darwin
import Foundation

/// Listens for commands on the data directory's socket.
///
/// Started only by the instance holding the directory lock, so "who executes a
/// command" and "who owns the data" are the same question by construction.
final class CommandServer: @unchecked Sendable {
    private let directory: URL
    private let handler: @Sendable (AppCommandRequest) async -> AppCommandResponse
    private let queue = DispatchQueue(label: "com.dimstunt.Vedivox.commandServer", qos: .userInitiated)

    private var listenDescriptor: Int32 = -1
    private var source: DispatchSourceRead?

    var socketURL: URL { CommandSocket.url(in: directory) }

    init(
        directory: URL,
        handler: @escaping @Sendable (AppCommandRequest) async -> AppCommandResponse
    ) {
        self.directory = directory
        self.handler = handler
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() throws {
        let path = socketURL.path

        // A socket file outlives the process that made it. Its presence proves
        // nothing — only a refused connection separates "someone is listening"
        // from "debris left by a crash", and only the latter may be removed.
        if CommandSocket.isAlive(at: path) {
            Log.error("CommandServer: \(path) is already served by another process")
            throw CommandSocketError.bindFailed(path: path, errno: EADDRINUSE)
        }
        unlink(path)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Before socket(): an overlong path throws here, and a descriptor
        // opened first would never be closed.
        var address = try CommandSocket.address(for: path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CommandSocketError.socketFailed(errno: errno) }

        let bound = CommandSocket.withAddress(&address) { pointer, length in
            Darwin.bind(descriptor, pointer, length)
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw CommandSocketError.bindFailed(path: path, errno: code)
        }

        // The socket is a control channel into the app's data; no reason for
        // anyone but its owner to reach it.
        chmod(path, 0o600)

        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(path)
            throw CommandSocketError.listenFailed(errno: code)
        }

        listenDescriptor = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        self.source = source

        Log.info("CommandServer: listening on \(path)")
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenDescriptor >= 0 {
            Darwin.close(listenDescriptor)
            listenDescriptor = -1
            unlink(socketURL.path)
        }
    }

    // MARK: - Serving

    private func acceptOne() {
        let connection = Darwin.accept(listenDescriptor, nil, nil)
        guard connection >= 0 else { return }

        // A sender that stops talking mid-request must not pin a descriptor.
        CommandSocket.setTimeout(connection, seconds: 10)
        CommandSocket.suppressBrokenPipeSignal(connection)

        let handler = self.handler
        Task {
            defer { Darwin.close(connection) }

            let request: AppCommandRequest
            do {
                let data = try CommandSocket.readMessage(connection, limit: CommandSocket.requestLimit)
                request = try JSONDecoder().decode(AppCommandRequest.self, from: data)
            } catch CommandSocketError.noMessage {
                // A liveness probe: connect, say nothing, hang up. Answering
                // would be writing into a closed socket, and logging it would
                // bury real traffic under every `isServed` check.
                return
            } catch {
                Log.error("CommandServer: unreadable request — \(error)")
                let response = AppCommandResponse.failure(
                    "Could not read the command: \(error)",
                    reason: .invalidParameters
                )
                try? CommandSocket.writeAll(connection, try CommandSocket.encode(response))
                return
            }

            Log.info("CommandServer: \(request.command) \(request.params)")
            let response = await handler(request)
            Log.info("CommandServer: \(request.command) → \(response.ok ? "ok" : "failed: \(response.reason ?? "?")")")

            do {
                try CommandSocket.writeAll(connection, try CommandSocket.encode(response))
            } catch {
                Log.error("CommandServer: could not answer \(request.command) — \(error)")
            }
        }
    }
}
