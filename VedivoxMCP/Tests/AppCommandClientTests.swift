import Darwin
import Foundation
import Testing
@testable import VedivoxCLIKit
@testable import VedivoxMCPLib

/// A listening AF_UNIX socket at `path`; the backlog completes connects
/// without an accept loop. Returns the descriptor for the test to close.
private func listen(at path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        for (offset, byte) in path.utf8.enumerated() { buffer[offset] = byte }
        buffer[path.utf8.count] = 0
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    try #require(bound == 0)
    try #require(Darwin.listen(descriptor, 4) == 0)
    return descriptor
}

@Suite("App socket: liveness vs a closed door")
struct AppCommandClientTests {
    /// Short folder: a socket path must fit in 103 bytes.
    private func socketDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("no socket file and a dead socket both mean: not running")
    func notRunning() throws {
        let dir = try socketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try AppCommandClient.isServed(directory: dir) == false)

        // Bound, then the listener closes: the file stays, connect gets ECONNREFUSED.
        Darwin.close(try listen(at: AppCommandClient.socketPath(in: dir)))
        #expect(try AppCommandClient.isServed(directory: dir) == false)
    }

    @Test("a listening socket means: running")
    func running() throws {
        let dir = try socketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let descriptor = try listen(at: AppCommandClient.socketPath(in: dir))
        defer { Darwin.close(descriptor) }
        #expect(try AppCommandClient.isServed(directory: dir) == true)
    }

    @Test("connect refused by permissions is an error, not 'not running'")
    func denied() throws {
        let dir = try socketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = AppCommandClient.socketPath(in: dir)
        let descriptor = try listen(at: path)
        defer { Darwin.close(descriptor) }
        // No write permission on the socket file: connect fails with EACCES,
        // the same class of refusal a sandbox gives (EPERM).
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

        do {
            _ = try AppCommandClient.isServed(directory: dir)
            Issue.record("expected accessDenied")
        } catch {
            guard case .accessDenied(let deniedPath, _) = error else {
                Issue.record("expected accessDenied, got \(error)")
                return
            }
            #expect(deniedPath == path)
            #expect(error.description.contains(path))
            #expect(error.description.contains("sandbox.network.allowUnixSockets"))
            #expect(cliFailure(from: error).code == 3)
        }
    }

    @Test("the denial keeps exit code 3 when it comes back through an import tool")
    func deniedThroughImportTool() {
        let message = AppCommandError.accessDenied(path: "/x/command.sock", reason: "Operation not permitted").description
        #expect(throws: CLIFailure.unavailable(message)) {
            try CLIActionCore.withCLIDispatch { "Error: \(message)" }
        }
    }

    @Test("open blocked by Launch Services says to open Vedivox by hand")
    func launchBlocked() {
        let sandboxed = AppCommandClient.openFailure(
            status: 1,
            stderr: "The application /Applications/Vedivox.app cannot be opened for an unexpected reason, "
                + "error=Error Domain=NSOSStatusErrorDomain Code=-600 \"procNotFound: no eligible process\""
        )
        #expect(sandboxed.contains("open Vedivox by hand"))
        #expect(!sandboxed.contains("NSOSStatusErrorDomain"))

        let other = AppCommandClient.openFailure(status: 1, stderr: "Unable to find application named 'Vedivox'\n")
        #expect(other == "open exited with code 1: Unable to find application named 'Vedivox'")
    }

    /// `vedivox import` runs an MCP tool and reads its "Error: …" line. The code
    /// came from substrings, so the app's own refusals — which carry the
    /// reason in brackets — all fell to 1.
    @Test("vedivox import maps the app's reason and transport failures onto the exit-code table", arguments: [
        ("Import: file not found — /p/x.m4a [not_found]", Int32(2)),
        ("Import: cannot read the date “x” — use YYYY-MM-DD or ISO8601 [invalid_parameters]", 64),
        ("exchange with Vedivox failed: read errno 35", 3),
        ("socket path is longer than 103 bytes: /very/long", 3),
        ("Import of x.m4a failed: No readable audio in x.m4a [failed]", 1),
    ])
    func importExitCodes(message: String, code: Int32) {
        #expect(throws: CLIFailure(code: code, message: message)) {
            try CLIActionCore.withCLIDispatch { "Error: \(message)" }
        }
    }

    @Test("a refusal for bad parameters is exit 64, like bad arguments caught in the CLI")
    func invalidParametersIsUsage() {
        let response = AppCommandResponse(ok: false, message: "Unknown track “foo”", reason: "invalid_parameters")
        #expect(cliFailure(from: response)?.code == 64)
    }
}
