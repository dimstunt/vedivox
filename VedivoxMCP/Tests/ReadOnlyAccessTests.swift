import Foundation
import GRDB
import Testing
@testable import VedivoxMCPLib

/// Pins that this process only reads, and that reading does not fail just
/// because the app happens to be writing.
@Suite("Read-only database access")
struct ReadOnlyAccessTests {

    private func makeDatabaseFile() throws -> (path: String, cleanup: () -> Void) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vedivox-readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("Vedivox.sqlite").path

        var writerConfig = Configuration()
        writerConfig.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let writer = try DatabaseQueue(path: path, configuration: writerConfig)
        try writer.write { db in
            try db.execute(sql: "CREATE TABLE meetings (id TEXT PRIMARY KEY, title TEXT)")
            try db.execute(sql: "INSERT INTO meetings VALUES ('m1', 'Weekly')")
        }

        return (path, { try? FileManager.default.removeItem(at: directory) })
    }

    /// The whole point of the rename: the connection cannot write even if some
    /// future code tries to.
    @Test("the connection refuses to write")
    func testConnectionIsReadOnly() throws {
        let (path, cleanup) = try makeDatabaseFile()
        defer { cleanup() }

        let queue = try DatabaseQueue(path: path, configuration: DatabaseReader.configuration)

        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(sql: "UPDATE meetings SET title = 'changed' WHERE id = 'm1'")
            }
        }

        let title = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM meetings WHERE id = 'm1'")
        }
        #expect(title == "Weekly")
    }

    /// A monitoring loop polls while the app processes a meeting, so a read
    /// landing while the app holds the database is the normal case, not an
    /// edge one. A plain write transaction does not block a WAL reader, so
    /// the lock here is the one that does — an exclusive locking mode
    /// connection — released shortly after the read starts: without the
    /// busy timeout the read fails at once with SQLITE_BUSY.
    @Test("a read waits out the app's lock instead of failing")
    func testReadDuringWriteSucceeds() throws {
        let (path, cleanup) = try makeDatabaseFile()
        defer { cleanup() }

        let writer = try DatabaseQueue(path: path)
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA locking_mode = EXCLUSIVE")
            try db.execute(sql: "INSERT INTO meetings VALUES ('m2', 'In progress')")
        }
        // The exclusive mode keeps the lock after the commit; NORMAL plus one
        // access hands it back.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? writer.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA locking_mode = NORMAL")
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings")
            }
        }

        // Opened under the lock: an open WAL connection would itself keep the
        // writer from taking it, and opening already reads the schema.
        let reader = try DatabaseQueue(path: path, configuration: DatabaseReader.configuration)
        let count = try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings")
        }
        #expect(count == 2)
    }

    /// A missing database is a refusal, not an empty result. A polling loop
    /// that reads "no meetings" from a database it never opened would report
    /// success and stop waiting.
    @Test("a database that cannot be opened is refused, not reported as empty")
    func testMissingDatabaseIsRefused() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vedivox-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("Vedivox.sqlite").path
        #expect(!FileManager.default.fileExists(atPath: path))

        #expect(throws: (any Error).self) {
            _ = try DatabaseQueue(path: path, configuration: DatabaseReader.configuration)
        }
        // And nothing was created on the way: a read-only open of a missing
        // file must not leave an empty database behind for the app to find.
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
