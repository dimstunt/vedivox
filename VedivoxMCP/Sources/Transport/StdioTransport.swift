import Foundation

/// Line-based stdio transport for JSON-RPC over stdin/stdout.
///
/// All output goes to stdout. Debug/log output must use stderr.
package enum StdioTransport {
    /// Reads one line from stdin, stripping the trailing newline.
    ///
    /// - Returns: The line as `Data`, or `nil` on EOF.
    package static func readLine() -> Data? {
        guard let line = Swift.readLine(strippingNewline: true) else {
            return nil
        }
        return line.data(using: .utf8)
    }

    /// Writes data followed by a newline to stdout and flushes.
    package static func writeLine(_ data: Data) {
        let stdout = FileHandle.standardOutput
        stdout.write(data)
        stdout.write(Data([0x0A])) // newline
        // FileHandle.standardOutput is unbuffered on Darwin, but flush for safety
    }

    /// Writes a string message to stderr for debug logging.
    package static func log(_ message: String) {
        fputs(message + "\n", stderr)
    }
}
