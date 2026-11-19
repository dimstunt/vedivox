import Darwin
import Foundation

/// Errors from the command transport itself, as opposed to the command.
enum CommandSocketError: Error, CustomStringConvertible {
    case pathTooLong(path: String, limit: Int)
    case socketFailed(errno: Int32)
    case bindFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case connectFailed(path: String, errno: Int32)
    case ioFailed(errno: Int32)
    case malformedMessage
    /// The peer connected and hung up without sending anything — how liveness
    /// is probed, so it is expected traffic rather than an error to report.
    case noMessage
    case timedOut

    var description: String {
        switch self {
        case .pathTooLong(let path, let limit):
            return "socket path is \(path.utf8.count) bytes, limit is \(limit): \(path)"
        case .socketFailed(let code): return "socket() failed (errno \(code))"
        case .bindFailed(let path, let code): return "bind(\(path)) failed (errno \(code))"
        case .listenFailed(let code): return "listen() failed (errno \(code))"
        case .connectFailed(let path, let code): return "connect(\(path)) failed (errno \(code))"
        case .ioFailed(let code): return "socket i/o failed (errno \(code))"
        case .malformedMessage: return "malformed message"
        case .noMessage: return "peer sent nothing"
        case .timedOut: return "timed out"
        }
    }
}

/// Unix-domain socket plumbing shared by the listener and the sender.
///
/// The address is a path inside the data directory, which is what makes routing
/// correct by construction: the thing being addressed is the data, and only one
/// process can own it. Nothing here consults LaunchServices, so the choice of
/// recipient can no longer depend on which build was compiled last.
enum CommandSocket {
    static let fileName = "command.sock"

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, including the terminator.
    static let pathLimit = 103

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Addressing

    static func address(for path: String) throws -> sockaddr_un {
        guard path.utf8.count <= pathLimit else {
            throw CommandSocketError.pathTooLong(path: path, limit: pathLimit)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: pathLimit + 1) { chars in
                for (offset, byte) in path.utf8.enumerated() {
                    chars[offset] = CChar(bitPattern: byte)
                }
                chars[path.utf8.count] = 0
            }
        }

        return addr
    }

    static func withAddress<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        try withUnsafePointer(to: &addr) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                try body(generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    // MARK: - Liveness

    /// Whether something is currently listening on the socket.
    ///
    /// A socket file left behind by a crashed process still exists on disk but
    /// refuses connections — so the file's presence says nothing, and only an
    /// attempted connection distinguishes "in use" from "debris".
    static func isAlive(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        do {
            var addr = try address(for: path)
            let connected = withAddress(&addr) { pointer, length in
                Darwin.connect(descriptor, pointer, length)
            }
            return connected == 0
        } catch {
            return false
        }
    }

    // MARK: - Framing

    /// One JSON object per connection, terminated by a newline.
    ///
    /// A connection carries a single exchange, so the framing only has to mark
    /// where the request ends — no length prefixes, no multiplexing, nothing to
    /// get out of sync.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw CommandSocketError.ioFailed(errno: errno)
                }
                pointer += written
                remaining -= written
            }
        }
    }

    /// A request is a command name and a few flat fields; the largest real one
    /// carries a meeting description.
    static let requestLimit = 1 << 20

    /// Reads until the first newline, or EOF. `limit` bounds what a peer can
    /// make this process hold — the server passes `requestLimit`; an answer
    /// (a whole transcript from `transcribe_file`) is not bounded.
    static func readMessage(_ descriptor: Int32, limit: Int = .max) throws -> Data {
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw CommandSocketError.ioFailed(errno: errno)
            }
            if count == 0 { break }

            if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                accumulated.append(contentsOf: chunk[0..<newline])
                break
            }
            accumulated.append(contentsOf: chunk[0..<count])
            guard accumulated.count <= limit else { throw CommandSocketError.malformedMessage }
        }

        guard !accumulated.isEmpty else { throw CommandSocketError.noMessage }
        return accumulated
    }

    /// Turns a write to a hung-up peer into an `EPIPE` error instead of a
    /// signal.
    ///
    /// Not optional here: liveness is probed by connecting and closing without
    /// saying anything, so writing to a peer that has already gone is a routine
    /// event — and the default `SIGPIPE` would take the whole process down with
    /// it. That is exactly how it presented: the test runner died mid-suite
    /// with no failing assertion.
    static func suppressBrokenPipeSignal(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Bounds a blocking read or write so a wedged peer cannot hang the caller.
    static func setTimeout(_ descriptor: Int32, seconds: TimeInterval) {
        var tv = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}
