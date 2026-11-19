import Foundation
import GRDB

/// Guards the one operation that rewrites the whole database irreversibly.
///
/// Migrations are the only routine act that changes the structure of every
/// user's data at once, and 2026-08-08 showed the price of getting it wrong:
/// 158 meetings and 115 thousand segments. A backup turns that class of mistake
/// from lost data into lost time.
enum DatabaseSafety {
    static let backupsDirectoryName = "backups"

    enum Failure: Error, CustomStringConvertible {
        /// The database carries migrations this build has never heard of, so it
        /// was written by a newer one.
        case schemaFromNewerBuild(unknown: [String], databasePath: String, latestBackup: URL?)
        case backupFailed(destination: URL, underlying: String)

        var description: String {
            switch self {
            case .schemaFromNewerBuild(let unknown, let databasePath, let latestBackup):
                var text = """
                    The database at \(databasePath) was migrated by a newer build of Vedivox.
                    Migrations this build does not know: \(unknown.joined(separator: ", ")).
                    It cannot be used — your data has been left untouched.
                    """
                // Naming the backup is the difference between a message the
                // user can act on and "it won't start and I don't know why".
                if let latestBackup {
                    text += "\nMost recent backup: \(latestBackup.path)"
                } else {
                    text += "\nThere are no backups in the data directory."
                }
                return text
            case .backupFailed(let destination, let underlying):
                return """
                    Could not back the database up to \(destination.path): \(underlying).
                    No migrations were applied.
                    """
            }
        }
    }

    // MARK: - Schema Version

    /// Migrations recorded in the database that this build does not know.
    ///
    /// The set of applied identifiers is already in the database and cannot
    /// drift; `PRAGMA user_version` would have to be maintained by hand and
    /// would disagree with `grdb_migrations` after the first mistake.
    static func unknownMigrations(in db: Database, migrator: DatabaseMigrator) throws -> [String] {
        let known = Set(migrator.migrations)
        return try migrator.appliedIdentifiers(db).subtracting(known).sorted()
    }

    /// Migrations this build knows that the database has not had applied yet.
    static func pendingMigrations(in db: Database, migrator: DatabaseMigrator) throws -> [String] {
        let applied = try migrator.appliedIdentifiers(db)
        return migrator.migrations.filter { !applied.contains($0) }
    }

    // MARK: - Backups

    static func backupsDirectory(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(backupsDirectoryName, isDirectory: true)
    }

    /// Automatic backups this code has made are kept to this many; older ones
    /// go. Hand-made copies (any other name) are never touched.
    static let backupsToKeep = 3

    /// What the name of an automatic backup starts with; the stamp follows.
    static let backupPrefix = "Vedivox-"

    /// `Vedivox-<stamp>.sqlite` or `Vedivox-<stamp>-before-<migration>.sqlite`, so the
    /// name says what the copy predates and restoring by hand needs no notes.
    static func backupURL(in dataDirectory: URL, at date: Date, before migration: String? = nil) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var name = backupPrefix + formatter.string(from: date)
        if let migration {
            let safe = migration.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
            name += "-before-\(String(safe))"
        }
        return backupsDirectory(in: dataDirectory).appendingPathComponent("\(name).sqlite", isDirectory: false)
    }

    /// Whether a file name is one `backupURL` produces — the only files
    /// retention may delete.
    static func isAutomaticBackupName(_ name: String) -> Bool {
        backupStamp(in: name) != nil
    }

    /// The `yyyyMMdd-HHmmss` in the name of an automatic backup; nil for any
    /// other file. The stamp, not the whole name, is what orders the copies:
    /// a library that came over from the old name has copies under both
    /// prefixes, and they rotate as one set.
    static func backupStamp(in name: String) -> Substring? {
        guard let prefix = [backupPrefix, LegacyNames.backupPrefix].first(where: name.hasPrefix),
              name.hasSuffix(".sqlite") else { return nil }
        let body = name.dropFirst(prefix.count).dropLast(7)
        let stamp = body.prefix(15)
        guard stamp.count == 15, stamp.dropFirst(8).first == "-",
              stamp.filter(\.isNumber).count == 14 else { return nil }
        let rest = body.dropFirst(15)
        return rest.isEmpty || rest.hasPrefix("-before-") ? stamp : nil
    }

    /// Deletes automatic backups beyond the newest `keep`, with their `-wal` and
    /// `-shm` sidecars. The stamp in the name orders them; modification dates
    /// would be rewritten by a restore.
    static func pruneBackups(in dataDirectory: URL, keep: Int = backupsToKeep) {
        let directory = backupsDirectory(in: dataDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let automatic = entries
            .compactMap { entry in backupStamp(in: entry.lastPathComponent).map { (stamp: $0, url: entry) } }
            .sorted { $0.stamp > $1.stamp }
            .map(\.url)
        if automatic.count <= keep {
            Log.info("DatabaseSafety: \(automatic.count) automatic backup(s), nothing to rotate")
        }
        for stale in automatic.dropFirst(keep) {
            do {
                try FileManager.default.removeItem(at: stale)
                for sidecar in ["-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: stale.path + sidecar)
                }
                Log.info("DatabaseSafety: removed old backup \(stale.lastPathComponent)")
            } catch {
                Log.warning("DatabaseSafety: could not remove old backup \(stale.lastPathComponent): \(error)")
            }
        }
    }

    /// The most recent automatic backup, if any.
    static func latestBackup(in dataDirectory: URL) -> URL? {
        let directory = backupsDirectory(in: dataDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return entries
            .filter { $0.pathExtension == "sqlite" }
            .max { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate < rightDate
            }
    }

    /// Copies the database with `VACUUM INTO`.
    ///
    /// Atomic and consistent with respect to the WAL, and it does not require
    /// stopping writers. Copying the file instead would produce a backup
    /// missing whatever the WAL still holds — a copy that looks fine until it
    /// is needed.
    static func makeBackup(of queue: DatabaseQueue, to destination: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // VACUUM INTO refuses to overwrite, which is the behaviour we want.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [destination.path])
            }
        } catch {
            throw Failure.backupFailed(destination: destination, underlying: "\(error)")
        }
    }

    // MARK: - The Guard

    /// Refuses a database from a newer build, and backs one up before migrating.
    ///
    /// Returns the backup that was made, or `nil` when the schema already
    /// matched and there was nothing to protect against.
    @discardableResult
    static func prepareForMigration(
        _ queue: DatabaseQueue,
        migrator: DatabaseMigrator,
        databasePath: String,
        dataDirectory: URL,
        now: Date = Date(),
        willBackUp: () -> Void = {}
    ) throws -> URL? {
        let unknown = try queue.read { try unknownMigrations(in: $0, migrator: migrator) }
        guard unknown.isEmpty else {
            throw Failure.schemaFromNewerBuild(
                unknown: unknown,
                databasePath: databasePath,
                latestBackup: latestBackup(in: dataDirectory)
            )
        }

        let pending = try queue.read { try pendingMigrations(in: $0, migrator: migrator) }
        guard !pending.isEmpty else {
            // Every launch, not only after a migration: months without one
            // would otherwise let copies pile up uncounted.
            pruneBackups(in: dataDirectory)
            return nil
        }

        let destination = backupURL(in: dataDirectory, at: now, before: pending.first)
        willBackUp()
        try makeBackup(of: queue, to: destination)
        Log.info(
            "DatabaseSafety: backed up to \(destination.path) before applying "
            + "\(pending.count) migration(s): \(pending.joined(separator: ", "))"
        )
        pruneBackups(in: dataDirectory)
        return destination
    }

    /// Brings the schema up to date — refuse a newer one, copy, migrate — and
    /// says what it is doing while that takes time. A launch with nothing to
    /// apply reports nothing; an update that was announced always ends with
    /// `nil`, failed or not.
    static func update(
        _ queue: DatabaseQueue,
        migrator: DatabaseMigrator,
        databasePath: String,
        dataDirectory: URL,
        report: (LibraryUpdate?) -> Void = LibraryUpdate.report
    ) throws {
        var announced = false
        defer { if announced { report(nil) } }
        try prepareForMigration(
            queue, migrator: migrator, databasePath: databasePath, dataDirectory: dataDirectory
        ) {
            announced = true
            report(.backingUp)
        }
        if announced { report(.migrating) }
        try migrator.migrate(queue)
    }
}

/// What the database is busy with before the app can read it, when a new build
/// changes the schema: a full copy first, then the migrations. On a large
/// library that is a minute or more, and every query waits for it — the window
/// showed an empty library, and each section opened onto the same wait.
enum LibraryUpdate: Equatable, Sendable {
    case backingUp
    case migrating

    private static let stream = AsyncStream.makeStream(of: LibraryUpdate?.self)

    /// The phases as they are reported; `nil` ends an update. Buffered, so a
    /// phase reported before anyone listens is not lost. One reader.
    static var phases: AsyncStream<LibraryUpdate?> { stream.stream }

    static func report(_ phase: LibraryUpdate?) {
        stream.continuation.yield(phase)
    }
}
