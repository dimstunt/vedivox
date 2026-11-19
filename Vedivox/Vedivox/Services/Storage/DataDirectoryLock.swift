import Darwin
import Foundation

/// Who is currently working with a data directory.
///
/// Written into the lock file by the holder so a losing instance can say which
/// build won, activate it, and — per design decision 3 — launch exactly that
/// bundle rather than whichever copy LaunchServices happens to pick.
struct DataDirectoryHolder: Codable, Sendable, Equatable {
    var pid: Int32
    var bundlePath: String
    var startedAt: Date

    static func current() -> DataDirectoryHolder {
        DataDirectoryHolder(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundlePath: Bundle.main.bundlePath,
            startedAt: Date()
        )
    }
}

/// Result of trying to claim a data directory.
enum DataDirectoryClaim {
    case acquired(DataDirectoryLock)
    /// Another process holds the directory. The holder is `nil` only when the
    /// lock file could not be read — the claim still failed.
    case busy(DataDirectoryHolder?)
    /// The directory cannot be locked at all: it cannot be created or written,
    /// or the volume does not support the lock. Nobody else has it — the user
    /// has to be told, with this reason.
    case unavailable(String)
}

/// Exclusive claim on a data directory, held for the lifetime of the process.
///
/// `flock` on a descriptor that is never closed. The kernel releases the lock
/// when the process dies, so a stale lock does not exist by construction: the
/// "previous instance crashed" case needs no cleanup code, no PID liveness
/// check, and no manual unlock. That is the whole reason for choosing it over a
/// pid file or `NSDistributedLock` (design decision 1).
///
/// The unit of exclusivity is the directory, not the application identifier,
/// because what is being protected is the data. Two builds with different
/// identifiers pointed at one directory are exactly as dangerous as two copies
/// of the same build — and two instances on *different* directories must be
/// able to run at once, which is what makes debugging on a copy possible.
final class DataDirectoryLock: @unchecked Sendable {
    static let lockFileName = "instance.lock"

    /// The lock held by this process, if any. Retained so the descriptor lives
    /// as long as the process does.
    private(set) nonisolated(unsafe) static var current: DataDirectoryLock?

    let url: URL
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    static func lockFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(lockFileName, isDirectory: false)
    }

    /// Claims `directory` for this process.
    ///
    /// On success the holder record is written into the lock file and the lock
    /// is retained in `current`.
    @discardableResult
    static func acquire(
        in directory: URL,
        holder: DataDirectoryHolder = .current()
    ) -> DataDirectoryClaim {
        let url = lockFileURL(in: directory)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            // The directory cannot be locked at all. Refusing to start is the
            // safe reading (the alternative is two instances on one directory
            // with no way to tell) — but not as "busy": that exits without a
            // word, which is right only when another instance really has it.
            let reason = "\(url.path): \(String(cString: strerror(errno)))"
            Log.error("DataDirectoryLock: cannot open \(reason)")
            return .unavailable(reason)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            Darwin.close(descriptor)
            guard reason == EWOULDBLOCK else {
                let text = "\(url.path): \(String(cString: strerror(reason)))"
                Log.error("DataDirectoryLock: cannot lock \(text)")
                return .unavailable(text)
            }
            let existing = readHolder(in: directory)
            Log.info(
                "DataDirectoryLock: \(directory.path) is held by "
                + (existing.map { "pid \($0.pid) at \($0.bundlePath)" } ?? "an unknown process")
                + " (errno \(reason))"
            )
            return .busy(existing)
        }

        let lock = DataDirectoryLock(url: url, descriptor: descriptor)
        lock.write(holder)
        current = lock
        Log.info("DataDirectoryLock: holding \(directory.path) as pid \(holder.pid)")
        return .acquired(lock)
    }

    /// Reads the holder record without taking the lock.
    ///
    /// A record may describe a process that is already gone — the lock, not the
    /// file, is the source of truth about ownership.
    static func readHolder(in directory: URL) -> DataDirectoryHolder? {
        guard let data = try? Data(contentsOf: lockFileURL(in: directory)), !data.isEmpty else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DataDirectoryHolder.self, from: data)
    }

    /// Replaces the lock file contents with the holder record.
    ///
    /// Only ever called after the lock is held, so it cannot destroy another
    /// instance's record.
    private func write(_ holder: DataDirectoryHolder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(holder) else { return }

        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(descriptor, base, buffer.count)
        }
        fsync(descriptor)
    }

    /// Releases the claim.
    ///
    /// The app never calls this — the process holding the directory holds it
    /// until it exits. Tests do, to run more than one claim in one process.
    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
        if Self.current === self { Self.current = nil }
    }
}
