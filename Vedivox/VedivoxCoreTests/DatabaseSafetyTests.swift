import GRDB
import XCTest

/// Pins the two promises around migrations: a database from a newer build is
/// refused untouched, and one that is behind is copied before it is changed.
final class DatabaseSafetyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vedivox-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    // MARK: - Fixtures

    /// A migrator whose migrations each create one identifiable table, so a
    /// backup can be checked for what it does and does not contain.
    private func migrator(_ identifiers: [String]) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for identifier in identifiers {
            let table = identifier.replacingOccurrences(of: "-", with: "_")
            migrator.registerMigration(identifier) { db in
                try db.execute(sql: "CREATE TABLE \(table) (id INTEGER PRIMARY KEY)")
            }
        }
        return migrator
    }

    private func makeDatabase(migratedWith identifiers: [String]) throws -> (queue: DatabaseQueue, path: String) {
        let path = root.appendingPathComponent("Vedivox.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try migrator(identifiers).migrate(queue)
        return (queue, path)
    }

    private func tableExists(_ name: String, in queue: DatabaseQueue) throws -> Bool {
        try queue.read { db in try db.tableExists(name) }
    }

    private func backupFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: DatabaseSafety.backupsDirectory(in: root),
            includingPropertiesForKeys: nil
        )) ?? []
    }

    // MARK: - A Newer Database Is Refused

    func testDatabaseFromANewerBuildIsRefused() throws {
        let (queue, path) = try makeDatabase(migratedWith: ["v1", "v2", "v999-from-the-future"])

        XCTAssertThrowsError(
            try DatabaseSafety.prepareForMigration(
                queue, migrator: migrator(["v1", "v2"]), databasePath: path, dataDirectory: root
            )
        ) { error in
            guard case DatabaseSafety.Failure.schemaFromNewerBuild(let unknown, _, _) = error else {
                return XCTFail("expected schemaFromNewerBuild, got \(error)")
            }
            XCTAssertEqual(unknown, ["v999-from-the-future"])
        }
    }

    /// Refusing has to leave the data exactly as it was — that is the whole
    /// point of refusing rather than trying to reconcile the schema.
    func testRefusedDatabaseIsLeftUntouched() throws {
        let (queue, path) = try makeDatabase(migratedWith: ["v1", "v999-from-the-future"])
        try queue.write { db in try db.execute(sql: "INSERT INTO v1 (id) VALUES (1)") }

        _ = try? DatabaseSafety.prepareForMigration(
            queue, migrator: migrator(["v1", "v2"]), databasePath: path, dataDirectory: root
        )

        let rows = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v1") }
        XCTAssertEqual(rows, 1)
        XCTAssertFalse(try tableExists("v2", in: queue), "a refused database must not be migrated")
        XCTAssertTrue(backupFiles().isEmpty, "nothing was changed, so nothing needed backing up")
    }

    /// Without a path to restore from, the refusal is just "the app will not
    /// start and it is unclear what to do".
    func testRefusalNamesTheLatestBackup() throws {
        let backup = DatabaseSafety.backupURL(in: root, at: Date())
        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: backup.path, contents: Data("x".utf8))

        let (queue, path) = try makeDatabase(migratedWith: ["v1", "v999-from-the-future"])

        XCTAssertThrowsError(
            try DatabaseSafety.prepareForMigration(
                queue, migrator: migrator(["v1"]), databasePath: path, dataDirectory: root
            )
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains(backup.path), "refusal should name the backup, said: \(message)")
            XCTAssertTrue(message.contains("v999-from-the-future"), "refusal should name what migrated it")
        }
    }

    // MARK: - The Wait Is Announced

    /// The copy and the migrations take a minute or more on a large library,
    /// and every query waits for them: the window showed an empty library
    /// with nothing to say why.
    func testAnUpdateSaysWhatItIsDoing() throws {
        let (queue, path) = try makeDatabase(migratedWith: ["v1"])
        var phases: [LibraryUpdate?] = []

        try DatabaseSafety.update(
            queue, migrator: migrator(["v1", "v2"]), databasePath: path, dataDirectory: root
        ) { phases.append($0) }

        XCTAssertEqual(phases, [.backingUp, .migrating, nil])
        XCTAssertTrue(try tableExists("v2", in: queue))
    }

    /// An ordinary launch has nothing to apply and must not flash a banner.
    func testALaunchWithoutMigrationsAnnouncesNothing() throws {
        let (queue, path) = try makeDatabase(migratedWith: ["v1", "v2"])
        var phases: [LibraryUpdate?] = []

        try DatabaseSafety.update(
            queue, migrator: migrator(["v1", "v2"]), databasePath: path, dataDirectory: root
        ) { phases.append($0) }

        XCTAssertEqual(phases, [])
    }

    /// A banner nobody takes down would outlive the alert about the failure.
    func testAFailedUpdateEndsItsAnnouncement() throws {
        struct Broken: Error {}
        let (queue, path) = try makeDatabase(migratedWith: ["v1"])
        var failing = migrator(["v1"])
        failing.registerMigration("v2") { _ in throw Broken() }
        var phases: [LibraryUpdate?] = []

        XCTAssertThrowsError(try DatabaseSafety.update(
            queue, migrator: failing, databasePath: path, dataDirectory: root
        ) { phases.append($0) })

        XCTAssertEqual(phases, [.backingUp, .migrating, nil])
    }

    // MARK: - A Database Behind Is Backed Up First

    func testBackupIsMadeBeforeMigrating() throws {
        let (queue, path) = try makeDatabase(migratedWith: ["v1"])
        try queue.write { db in try db.execute(sql: "INSERT INTO v1 (id) VALUES (7)") }

        let full = migrator(["v1", "v2"])
        let backup = try DatabaseSafety.prepareForMigration(
            queue, migrator: full, databasePath: path, dataDirectory: root
        )

        let backupURL = try XCTUnwrap(backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // The copy is only useful if it predates the change.
        let copy = try DatabaseQueue(path: backupURL.path)
        XCTAssertTrue(try tableExists("v1", in: copy))
        XCTAssertFalse(try tableExists("v2", in: copy), "the backup must be from before the migration")
        XCTAssertEqual(try copy.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v1") }, 1)

        try full.migrate(queue)
        XCTAssertTrue(try tableExists("v2", in: queue))
    }

    /// An ordinary launch has no migrations to apply, and must not pay for a
    /// copy of a 180 MB database.
    func testNoBackupWhenTheSchemaAlreadyMatches() throws {
        let (queue, path) = try makeDatabase(migratedWith: ["v1", "v2"])

        let backup = try DatabaseSafety.prepareForMigration(
            queue, migrator: migrator(["v1", "v2"]), databasePath: path, dataDirectory: root
        )

        XCTAssertNil(backup)
        XCTAssertTrue(backupFiles().isEmpty)
    }

    /// No copy, no migration. A migration that runs anyway is precisely the
    /// unprotected operation this guard exists to prevent.
    func testMigrationsDoNotRunWhenTheBackupFails() throws {
        let (queue, path) = try makeDatabase(migratedWith: ["v1"])
        let unusable = URL(fileURLWithPath: "/dev/null/definitely-not-a-directory", isDirectory: true)

        XCTAssertThrowsError(
            try DatabaseSafety.prepareForMigration(
                queue, migrator: migrator(["v1", "v2"]), databasePath: path, dataDirectory: unusable
            )
        ) { error in
            guard case DatabaseSafety.Failure.backupFailed = error else {
                return XCTFail("expected backupFailed, got \(error)")
            }
        }

        XCTAssertFalse(try tableExists("v2", in: queue), "migrations must not run without a backup")
    }

    // MARK: - Link To The Real Migrator

    /// Guards against the check being vacuous: a database this build creates
    /// itself must contain nothing this build considers unknown.
    func testRealMigratorLeavesNothingUnknown() throws {
        let path = root.appendingPathComponent("Real.sqlite").path
        let queue = try DatabaseQueue(path: path)
        let real = DatabaseManager.migrator
        try real.migrate(queue)

        let unknown = try queue.read { db in
            try DatabaseSafety.unknownMigrations(in: db, migrator: real)
        }
        XCTAssertEqual(unknown, [])

        let backup = try DatabaseSafety.prepareForMigration(
            queue, migrator: real, databasePath: path, dataDirectory: root
        )
        XCTAssertNil(backup, "a database this build just created needs no backup")
    }


    // MARK: - Naming And Retention

    /// Restoring by hand starts from the file name: it has to say what the
    /// copy predates.
    func testBackupNameSaysWhichMigrationItPrecedes() throws {
        let (queue, path) = try makeDatabase(migratedWith: ["v1"])

        let backup = try XCTUnwrap(DatabaseSafety.prepareForMigration(
            queue, migrator: migrator(["v1", "v2-add-thing"]), databasePath: path, dataDirectory: root
        ))

        XCTAssertTrue(backup.lastPathComponent.hasSuffix("-before-v2-add-thing.sqlite"), backup.lastPathComponent)
        XCTAssertTrue(DatabaseSafety.isAutomaticBackupName(backup.lastPathComponent))
    }

    /// Only the newest automatic copies stay; anything named by a person is
    /// not ours to delete.
    func testOldAutomaticBackupsArePruned() throws {
        let directory = DatabaseSafety.backupsDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = [
            "Vedivox-20260101-000000.sqlite",
            "Vedivox-20260102-000000-before-v2.sqlite",
            "Vedivox-20260103-000000.sqlite",
            "Vedivox-20260104-000000-pre-manual-experiment.sqlite",
            "Vedivox.sqlite.backup-20260507-014915",
        ]
        for name in existing {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let (queue, path) = try makeDatabase(migratedWith: ["v1"])

        let backup = try XCTUnwrap(DatabaseSafety.prepareForMigration(
            queue, migrator: migrator(["v1", "v2"]), databasePath: path, dataDirectory: root
        ))

        let remaining = Set(backupFiles().map(\.lastPathComponent))
        XCTAssertFalse(remaining.contains("Vedivox-20260101-000000.sqlite"), "oldest automatic copy goes")
        XCTAssertTrue(remaining.contains("Vedivox-20260102-000000-before-v2.sqlite"))
        XCTAssertTrue(remaining.contains("Vedivox-20260103-000000.sqlite"))
        XCTAssertTrue(remaining.contains("Vedivox-20260104-000000-pre-manual-experiment.sqlite"), "hand-made copies stay")
        XCTAssertTrue(remaining.contains("Vedivox.sqlite.backup-20260507-014915"), "hand-made copies stay")
        XCTAssertTrue(remaining.contains(backup.lastPathComponent))
        XCTAssertEqual(remaining.filter(DatabaseSafety.isAutomaticBackupName).count, DatabaseSafety.backupsToKeep)
    }

    /// Rotation runs on an ordinary launch too, and takes each copy's journal
    /// files with it. A hand-made copy named in the automatic copies' format
    /// rotates like an automatic one.
    func testLaunchWithoutMigrationsPrunesBackupsAndSidecars() throws {
        let directory = DatabaseSafety.backupsDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let automatic = (1 ... 5).map { "Vedivox-2026010\($0)-000000.sqlite" }
        let documentedManual = "Vedivox-20260106-120000-before-cleanup.sqlite"
        let manual = "Vedivox-2026-10-02-before-merge.sqlite"
        for name in automatic + [documentedManual, manual] {
            for suffix in ["", "-wal", "-shm"] {
                FileManager.default.createFile(
                    atPath: directory.appendingPathComponent(name + suffix).path, contents: Data("x".utf8)
                )
            }
        }
        let (queue, path) = try makeDatabase(migratedWith: ["v1"])

        let backup = try DatabaseSafety.prepareForMigration(
            queue, migrator: migrator(["v1"]), databasePath: path, dataDirectory: root
        )

        XCTAssertNil(backup, "no migrations, no new copy")
        XCTAssertTrue(DatabaseSafety.isAutomaticBackupName(documentedManual))
        var expected: Set<String> = []
        for name in [documentedManual, automatic[4], automatic[3], manual] {
            for suffix in ["", "-wal", "-shm"] { expected.insert(name + suffix) }
        }
        XCTAssertEqual(Set(backupFiles().map(\.lastPathComponent)), expected)
    }
}
