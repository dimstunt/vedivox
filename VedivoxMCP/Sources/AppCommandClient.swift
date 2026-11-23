import Darwin
import Foundation

/// The Vedivox data directory, as seen from outside the app.
///
/// Mirrors the app's resolver. The duplication is deliberate and bounded: this
/// is a separate package, and the alternative — a shared module — buys one copy
/// of thirty lines at the cost of coupling the MCP server's build to the app's.
package enum VedivoxDataDirectory {
    package static let environmentKey = "VEDIVOX_DATA_DIR"

    package static var root: URL {
        if let configured = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespaces), !configured.isEmpty {
            return URL(
                fileURLWithPath: (configured as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Vedivox", isDirectory: true)
    }
}

/// A command addressed to the running Vedivox instance.
///
/// Wire format mirrors `AppCommandRequest` in the app: a name plus flat string
/// parameters, one JSON object per connection, newline-terminated.
package struct AppCommandRequest: Codable, Sendable {
    package var command: String
    package var params: [String: String]

    package init(command: String, params: [String: String] = [:]) {
        self.command = command
        self.params = params
    }
}

/// What the app reports back.
///
/// `ok` describes the requested action, not its delivery.
package struct AppCommandResponse: Codable, Sendable {
    package var ok: Bool
    package var message: String
    package var reason: String?
    /// Flat result fields (e.g. `meeting_id`); absent for most commands.
    package var data: [String: String]? = nil
}

package enum AppCommandName {
    package static let openMeeting = "open_meeting"
    package static let reprocessMeeting = "reprocess_meeting"
    package static let importFile = "import_file"
    package static let transcribeFile = "transcribe_file"
    package static let exportMeeting = "export_meeting"
    package static let ping = "ping"

    // Data changes travel the same socket: the app is the only writer.
    package static let updateSpeaker = "update_speaker"
    package static let mergeSpeakers = "merge_speakers"
    package static let updateSegment = "update_segment"
    package static let updateMeeting = "update_meeting"
    package static let deleteMeetings = "delete_meetings"
    package static let splitMeeting = "split_meeting"
    package static let trimMeeting = "trim_meeting"
    package static let mergeMeetings = "merge_meetings"
    package static let undoMeetingEdit = "undo_meeting_edit"
    package static let createSeries = "create_series"
    package static let updateSeries = "update_series"
    package static let deleteSeries = "delete_series"
    package static let markExcluded = "mark_excluded"
    package static let unmark = "unmark"
    package static let startRecording = "start_recording"
    package static let stopRecording = "stop_recording"
    package static let liveTranscript = "live_transcript"
    package static let compactAudio = "compact_audio"
    package static let diagnoseMute = "diagnose_mute"

    // Listen queue (listen-queue § 8).
    package static let listListenQueue = "list_listen_queue"
    package static let assignVoice = "assign_voice"
    package static let skipVoice = "skip_voice"
    package static let splitVoice = "split_voice"
    package static let assignRange = "assign_range"
    package static let pinSpeakers = "pin_speakers"
}

package enum AppCommandError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case notReachable(String)
    case launchFailed(String)
    case ioFailed(String)
    /// connect() refused by permissions (EPERM/EACCES): the app may well be
    /// running, the caller is not allowed to reach it — typically a sandbox.
    case accessDenied(path: String, reason: String)

    package var description: String {
        switch self {
        case .pathTooLong(let path): return "socket path is longer than 103 bytes: \(path)"
        case .notReachable(let detail): return "Vedivox is not answering: \(detail)"
        case .launchFailed(let detail): return "could not launch Vedivox: \(detail)"
        case .ioFailed(let detail): return "exchange with Vedivox failed: \(detail)"
        case .accessDenied(let path, let reason):
            return "access to the Vedivox socket \(path) is denied (\(reason)) — running inside a sandbox? "
                + "Allow this socket for the caller (Claude Code: sandbox.network.allowUnixSockets)"
        }
    }
}

/// Sends commands to the Vedivox instance that owns the data directory.
///
/// Replaces handing a `vedivox://` URL to `/usr/bin/open`: that call reports only
/// that the system accepted the link, which is why a reprocess that never ran
/// came back as success on 2026-08-14. Here the answer describes what the app
/// actually did.
package enum AppCommandClient {
    static let socketFileName = "command.sock"
    static let lockFileName = "instance.lock"
    static let pathLimit = 103

    package static func socketPath(in directory: URL = VedivoxDataDirectory.root) -> String {
        directory.appendingPathComponent(socketFileName, isDirectory: false).path
    }

    /// Whether an instance is currently answering for this data directory.
    /// Throws `accessDenied` instead of answering false: a closed socket says
    /// nothing about the app, and "not running" would make `run` launch a second copy.
    package static func isServed(directory: URL = VedivoxDataDirectory.root) throws(AppCommandError) -> Bool {
        let path = socketPath(in: directory)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            Darwin.close(try connect(to: path))
            return true
        } catch .accessDenied(let path, let reason) {
            throw .accessDenied(path: path, reason: reason)
        } catch {
            return false
        }
    }

    /// Sends a command, launching Vedivox first if nothing is serving.
    ///
    /// - Parameter timeout: how long to wait for the app to finish the action.
    ///   Generous by default: a reprocess runs a full transcription pass, and
    ///   reporting a timeout as failure would be its own kind of lie.
    package static func run(
        _ request: AppCommandRequest,
        directory: URL = VedivoxDataDirectory.root,
        timeout: TimeInterval = 1800
    ) throws -> AppCommandResponse {
        if try !isServed(directory: directory) {
            try launchHolder(for: directory)
            try waitUntilServed(directory: directory, deadline: 60)
        }
        return try send(request, directory: directory, timeout: timeout)
    }

    // MARK: - Launching

    /// Starts the build that last owned this data directory.
    ///
    /// The bundle path comes from the lock file rather than from
    /// LaunchServices. That is the whole point: on the machine where this went
    /// wrong there were eleven registered copies, and the system's choice
    /// changed after every rebuild.
    static func launchHolder(for directory: URL) throws {
        let arguments: [String]
        if let bundlePath = recordedBundlePath(in: directory),
           FileManager.default.fileExists(atPath: bundlePath) {
            arguments = ["-g", "-j", "-a", bundlePath]
        } else {
            // No usable record — first run, or the recorded build was removed.
            // Falling back to the scheme means LaunchServices chooses, which is
            // exactly the behaviour being replaced; it is acceptable only
            // because there is nothing better to go on.
            arguments = ["-g", "-j", "vedivox://"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw AppCommandError.launchFailed("\(error)")
        }
        let errText = String(bytes: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AppCommandError.launchFailed(openFailure(status: process.terminationStatus, stderr: errText))
        }
    }

    /// Launch Services closed to the caller (a sandbox) fails `open` with -600
    /// procNotFound or -10822; say so, since retrying cannot help.
    static func openFailure(status: Int32, stderr: String) -> String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["-600", "procNotFound", "-10822", "kLSServerCommunicationErr"].contains(where: detail.contains) {
            return "open exited with code \(status): Launch Services refused the launch, "
                + "probably a sandbox — open Vedivox by hand and retry"
        }
        return "open exited with code \(status)" + (detail.isEmpty ? "" : ": \(detail)")
    }

    /// The bundle path recorded by the instance that held the directory.
    static func recordedBundlePath(in directory: URL) -> String? {
        let url = directory.appendingPathComponent(lockFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["bundlePath"] as? String
    }

    static func waitUntilServed(directory: URL, deadline seconds: TimeInterval) throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if try isServed(directory: directory) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw AppCommandError.notReachable(
            "did not come up within \(Int(seconds))s (\(socketPath(in: directory)))"
        )
    }

    // MARK: - Transport

    package static func send(
        _ request: AppCommandRequest,
        directory: URL = VedivoxDataDirectory.root,
        timeout: TimeInterval
    ) throws -> AppCommandResponse {
        let path = socketPath(in: directory)
        let descriptor = try connect(to: path, timeout: timeout)
        defer { Darwin.close(descriptor) }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try writeAll(descriptor, payload)
        shutdown(descriptor, SHUT_WR)

        let data = try readMessage(descriptor)
        do {
            return try JSONDecoder().decode(AppCommandResponse.self, from: data)
        } catch {
            throw AppCommandError.ioFailed("could not parse the reply: \(error)")
        }
    }

    static func connect(to path: String, timeout: TimeInterval = 5) throws(AppCommandError) -> Int32 {
        guard path.utf8.count <= pathLimit else { throw AppCommandError.pathTooLong(path) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppCommandError.ioFailed("socket() errno \(errno)") }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: pathLimit + 1) { chars in
                for (offset, byte) in path.utf8.enumerated() { chars[offset] = CChar(bitPattern: byte) }
                chars[path.utf8.count] = 0
            }
        }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EPERM || code == EACCES {
                throw AppCommandError.accessDenied(path: path, reason: String(cString: strerror(code)))
            }
            throw AppCommandError.notReachable("connect(\(path)) errno \(code)")
        }

        return descriptor
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AppCommandError.ioFailed("write errno \(errno)")
                }
                pointer += written
                remaining -= written
            }
        }
    }

    static func readMessage(_ descriptor: Int32) throws -> Data {
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw AppCommandError.ioFailed("read errno \(errno)")
            }
            if count == 0 { break }
            if let newline = chunk[0 ..< count].firstIndex(of: 0x0A) {
                accumulated.append(contentsOf: chunk[0 ..< newline])
                break
            }
            accumulated.append(contentsOf: chunk[0 ..< count])
        }

        guard !accumulated.isEmpty else {
            throw AppCommandError.ioFailed("Vedivox closed the connection without answering")
        }
        return accumulated
    }
}

/// The single seam through which tools reach the running app.
///
/// One place, not one per tool: the honesty of the report is a property of this
/// hop, and duplicating it per call site is how one of the copies ends up still
/// reporting delivery as success.
package enum AppCommandDispatch {
    package nonisolated(unsafe) static var run: @Sendable (AppCommandRequest) throws -> AppCommandResponse = {
        try AppCommandClient.run($0)
    }

    /// Sends only when an instance is already serving; nil otherwise. For
    /// questions about what the app is doing right now — an app launched to be
    /// asked «what are you recording» has nothing to say.
    package nonisolated(unsafe) static var runIfServing: @Sendable (AppCommandRequest) throws -> AppCommandResponse? = {
        try AppCommandClient.isServed() ? AppCommandClient.send($0, timeout: 30) : nil
    }

    /// Renders a response as tool output, keeping the failure reason visible.
    package static func describe(_ response: AppCommandResponse) -> String {
        guard response.ok else {
            let reason = response.reason.map { " [\($0)]" } ?? ""
            return "Error: \(response.message)\(reason)"
        }
        return response.message
    }
}
