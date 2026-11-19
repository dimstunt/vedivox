import Darwin
import Foundation

/// Private scratch folders for the CLI and the MCP server.
///
/// FileManager.temporaryDirectory ignores $TMPDIR (it asks the system for the
/// per-user /var/folders dir), and a sandboxed caller such as Claude Code may
/// write only under $TMPDIR. The app is not sandboxed and runs as the same
/// user, so it reads a file handed over from either place.
package enum ScratchDirectory {
    package struct Failure: Error, CustomStringConvertible {
        package let message: String
        package var description: String { message }
    }

    /// `$TMPDIR` when set, else the system temporary directory.
    package static func base(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["TMPDIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
    }

    /// A new folder `<base>/<prefix>.XXXXXX`, mode 0700 (mkdtemp). The caller removes it.
    package static func make(
        prefix: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(Failure) -> URL {
        let template = base(environment: environment).appendingPathComponent("\(prefix).XXXXXX").path
        var bytes = Array(template.utf8CString)
        let made = bytes.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress).map { String(cString: $0) } }
        guard let made else {
            throw Failure(message: "cannot create a temporary folder \(template) — \(String(cString: strerror(errno)))")
        }
        return URL(fileURLWithPath: made, isDirectory: true)
    }
}
