import Foundation

/// Centralised file logger with rotation.
enum Log {

    enum Level: Int, Comparable {
        case debug = 0
        case info = 1
        /// Findings on the normal path — a threshold tripped, a fallback taken.
        /// Kept apart from `error` so `grep ERROR` still means "something broke".
        case warning = 2
        case error = 3

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var tag: String {
            switch self {
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warning: return "WARN"
            case .error: return "ERROR"
            }
        }
    }

    /// Minimum level to emit. Messages below this level are silently dropped.
    nonisolated(unsafe) static var level: Level = UserDefaults.standard.bool(forKey: "debugLogging") ? .debug : .info

    static func debug(_ message: @autoclosure () -> String, fileID: String = #fileID) {
        emit(.debug, message(), fileID: fileID)
    }

    static func info(_ message: @autoclosure () -> String, fileID: String = #fileID) {
        emit(.info, message(), fileID: fileID)
    }

    static func warning(_ message: @autoclosure () -> String, fileID: String = #fileID) {
        emit(.warning, message(), fileID: fileID)
    }

    static func error(_ message: @autoclosure () -> String, fileID: String = #fileID) {
        emit(.error, message(), fileID: fileID)
    }

    // MARK: - Private

    private static let maxFileSize: UInt64 = 10 * 1024 * 1024 // 10 MB
    private static let maxFileCount = 5 // vedivox.log + vedivox.1…4.log
    private static let queue = DispatchQueue(label: "com.dimstunt.Vedivox.logger", qos: .utility)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Not private: the directory is diagnostic information, and tests assert
    /// that logging has no path source of its own.
    static let logDirectory: URL = DataDirectory.logs

    private static let logFileURL: URL = logDirectory.appendingPathComponent("vedivox.log")

    private nonisolated(unsafe) static var fileHandle: FileHandle? = {
        let fm = FileManager.default
        try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: logFileURL)
    }()

    /// Extract the type name from a `#fileID` string (e.g. "Vedivox/SystemAudioCapture.swift" → "SystemAudioCapture").
    private static func component(from fileID: String) -> String {
        var name = fileID
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if name.hasSuffix(".swift") {
            name = String(name.dropLast(6))
        }
        return name
    }

    private static func emit(_ lvl: Level, _ message: String, fileID: String) {
        guard lvl >= level else { return }

        let comp = component(from: fileID)
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(lvl.tag)] [\(comp)] \(message)\n"

        queue.async {
            rotateIfNeeded()
            if let data = line.data(using: .utf8), let fileHandle {
                append(data, to: fileHandle)
            }
        }
    }

    /// Appends through the throwing calls. The older `write(_:)` raises an
    /// Objective-C exception when the write fails (a full disk), which Swift
    /// cannot catch: one log line took the app down mid-recording, and again
    /// at every launch, until space was freed. A line that cannot be written
    /// is dropped — there is nowhere to report it. Not private: tested.
    @discardableResult
    static func append(_ data: Data, to handle: FileHandle) -> Bool {
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize else { return }

        try? fileHandle?.close()
        fileHandle = nil
        shiftFiles(in: logDirectory, fileCount: maxFileCount)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
    }

    /// vedivox.log → vedivox.1.log → … → vedivox.(fileCount-1).log, the oldest dropped,
    /// and a fresh empty vedivox.log. Not private: tested.
    static func shiftFiles(in directory: URL, fileCount: Int) {
        let fm = FileManager.default
        try? fm.removeItem(at: directory.appendingPathComponent("vedivox.\(fileCount - 1).log"))
        for i in stride(from: fileCount - 2, through: 1, by: -1) {
            let src = directory.appendingPathComponent("vedivox.\(i).log")
            let dst = directory.appendingPathComponent("vedivox.\(i + 1).log")
            try? fm.moveItem(at: src, to: dst)
        }
        let current = directory.appendingPathComponent("vedivox.log")
        try? fm.moveItem(at: current, to: directory.appendingPathComponent("vedivox.1.log"))
        fm.createFile(atPath: current.path, contents: nil)
    }
}
