import XCTest

/// Pins the command transport: the address is the data directory, debris from a
/// crash does not block a restart, and a command that fails comes back as a
/// failure rather than as silence.
final class CommandSocketTests: XCTestCase {

    private var directories: [URL] = []
    private var servers: [CommandServer] = []

    private func makeDirectory() throws -> URL {
        // Short path on purpose: `sun_path` is 104 bytes, and the default
        // temporary directory plus a full UUID already crowds that limit.
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("vedivox-cmd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    @discardableResult
    private func startServer(
        in directory: URL,
        handler: @escaping @Sendable (AppCommandRequest) async -> AppCommandResponse
    ) throws -> CommandServer {
        let server = CommandServer(directory: directory, handler: handler)
        try server.start()
        servers.append(server)
        return server
    }

    override func tearDown() {
        for server in servers { server.stop() }
        servers = []
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Round Trip

    func testCommandReachesTheServerAndTheOutcomeComesBack() throws {
        let directory = try makeDirectory()
        let received = SendableBox<AppCommandRequest?>(nil)

        try startServer(in: directory) { request in
            received.value = request
            return .success("сделано: \(request.params["meeting_id"] ?? "")")
        }

        let response = try CommandClient.send(
            AppCommandRequest(command: AppCommandName.reprocessMeeting, params: ["meeting_id": "abc"]),
            to: directory,
            timeout: 5
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "сделано: abc")
        XCTAssertEqual(received.value?.command, AppCommandName.reprocessMeeting)
        XCTAssertEqual(received.value?.params["meeting_id"], "abc")
    }

    /// The whole point of the change: a command that was delivered but not
    /// carried out must not read as success.
    func testFailureIsReportedWithItsReason() throws {
        let directory = try makeDirectory()
        try startServer(in: directory) { _ in
            .failure("Встреча не найдена", reason: .notFound)
        }

        let response = try CommandClient.send(
            AppCommandRequest(command: AppCommandName.reprocessMeeting, params: ["meeting_id": "missing"]),
            to: directory,
            timeout: 5
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.reason, AppCommandResponse.Reason.notFound.rawValue)
        XCTAssertEqual(response.message, "Встреча не найдена")
    }

    // MARK: - Liveness

    func testNothingIsServedBeforeAServerStarts() throws {
        let directory = try makeDirectory()
        XCTAssertFalse(CommandClient.isServed(directory: directory))
    }

    func testDirectoryReportsServedWhileAServerRuns() throws {
        let directory = try makeDirectory()
        try startServer(in: directory) { _ in .success("ok") }
        XCTAssertTrue(CommandClient.isServed(directory: directory))
    }

    func testSendingWithNoServerFails() throws {
        let directory = try makeDirectory()
        XCTAssertThrowsError(
            try CommandClient.send(AppCommandRequest(command: AppCommandName.ping), to: directory, timeout: 2)
        )
    }

    // MARK: - Debris From A Crash

    /// A crashed instance leaves the socket file behind. The file alone must not
    /// stop the next instance from serving — otherwise every crash would need
    /// manual cleanup, the very failure mode `flock` was chosen to avoid for the
    /// lock.
    func testStaleSocketFileDoesNotBlockStartup() throws {
        let directory = try makeDirectory()
        let socketPath = CommandSocket.url(in: directory).path
        FileManager.default.createFile(atPath: socketPath, contents: Data("debris".utf8))
        XCTAssertFalse(CommandSocket.isAlive(at: socketPath))

        try startServer(in: directory) { _ in .success("ok") }

        let response = try CommandClient.send(
            AppCommandRequest(command: AppCommandName.ping), to: directory, timeout: 5
        )
        XCTAssertTrue(response.ok)
    }

    /// The live case is the opposite: a second server must not steal an address
    /// somebody is answering on.
    func testSecondServerOnALiveSocketIsRefused() throws {
        let directory = try makeDirectory()
        try startServer(in: directory) { _ in .success("first") }

        let second = CommandServer(directory: directory) { _ in .success("second") }
        XCTAssertThrowsError(try second.start())
        second.stop()

        // The first server is still answering — the refusal cost nothing.
        let response = try CommandClient.send(
            AppCommandRequest(command: AppCommandName.ping), to: directory, timeout: 5
        )
        XCTAssertEqual(response.message, "first")
    }

    // MARK: - Addressing Limits

    /// A peer that streams bytes with no newline is not sending a request. The
    /// server used to keep every byte: one stuck or hostile process of the
    /// same user could grow the app's memory without bound.
    func testARequestOverTheLimitIsRefusedNotAccumulated() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]) }
        CommandSocket.suppressBrokenPipeSignal(pair[1])

        let writer = Thread { [fd = pair[1]] in
            let chunk = [UInt8](repeating: 0x61, count: 64 * 1024)
            for _ in 0 ..< 4 where write(fd, chunk, chunk.count) > 0 {}
            close(fd)
        }
        writer.start()

        XCTAssertThrowsError(try CommandSocket.readMessage(pair[0], limit: 100 * 1024)) { error in
            guard case CommandSocketError.malformedMessage = error else {
                return XCTFail("expected malformedMessage, got \(error)")
            }
        }
    }

    func testARequestUnderTheLimitIsRead() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        try CommandSocket.writeAll(pair[1], Data("{\"command\":\"ping\"}\n".utf8))

        let message = try CommandSocket.readMessage(pair[0], limit: CommandSocket.requestLimit)
        XCTAssertEqual(String(bytes: message, encoding: .utf8), "{\"command\":\"ping\"}")
    }

    /// `sun_path` is 104 bytes. A configured data directory can exceed it, and a
    /// named error is the difference between a fixable message and a silent
    /// inability to accept commands.
    func testOverlongPathIsRejectedByName() {
        let long = "/tmp/" + String(repeating: "d", count: 200)
        XCTAssertThrowsError(try CommandSocket.address(for: long)) { error in
            guard case CommandSocketError.pathTooLong = error else {
                return XCTFail("expected pathTooLong, got \(error)")
            }
        }
    }
}

/// Minimal box for capturing a value out of a `@Sendable` handler in tests.
private final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
