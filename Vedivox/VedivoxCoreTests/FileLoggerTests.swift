import XCTest

final class FileLoggerTests: XCTestCase {

    /// `FileHandle.write(_:)` raises an Objective-C exception when the write
    /// fails — a full disk, a handle that went bad — and nothing in Swift can
    /// catch it: one log line took the app down, mid-recording, and again at
    /// every launch (the first thing a launch does is log). A handle that
    /// cannot be written stands in for the full disk.
    func testAFailedWriteDropsTheLineInsteadOfCrashing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vedivox-log-\(UUID().uuidString).log")
        try Data("existing\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let readOnly = try FileHandle(forReadingFrom: file)
        defer { try? readOnly.close() }

        XCTAssertFalse(Log.append(Data("new line\n".utf8), to: readOnly))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "existing\n")
    }

    func testAWriteAppends() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vedivox-log-\(UUID().uuidString).log")
        try Data("existing\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        XCTAssertTrue(Log.append(Data("new line\n".utf8), to: handle))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "existing\nnew line\n")
    }

    /// Rotation keeps the newest five files and never loses the current one
    /// vedivox.log becomes vedivox.1.log, vedivox.4.log is dropped.
    func testRotationShiftsFilesAndDropsTheOldest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vedivox-log-rotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["vedivox.log", "vedivox.1.log", "vedivox.2.log", "vedivox.3.log", "vedivox.4.log"] {
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }

        Log.shiftFiles(in: dir, fileCount: 5)

        func content(_ name: String) -> String? {
            try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        XCTAssertEqual(content("vedivox.log"), "", "a fresh, empty current file")
        XCTAssertEqual(content("vedivox.1.log"), "vedivox.log")
        XCTAssertEqual(content("vedivox.2.log"), "vedivox.1.log")
        XCTAssertEqual(content("vedivox.3.log"), "vedivox.2.log")
        XCTAssertEqual(content("vedivox.4.log"), "vedivox.3.log", "the oldest one is gone")
        XCTAssertNil(content("vedivox.5.log"))
    }
}
