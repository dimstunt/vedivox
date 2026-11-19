import Darwin
import GRDB
import XCTest

/// The first launch's takeover, run on a copy of a real library instead of a
/// made-up one. Skipped unless `TEST_RUNNER_VEDIVOX_LIBRARY_COPY` names a
/// directory laid out as:
///
///     <copy>/Vox/                      the library under its old name: the database
///                                      (a `VACUUM INTO` copy), some of `audio/`, `logs/`
///     <copy>/legacy-defaults.plist     `defaults export` of the old settings domain
///
/// It moves the copy, renames its files, runs the real migrator on the real
/// database and adopts the real settings into a throwaway domain. Never the
/// live library, never the app's own settings domain.
final class LibraryCopyMigrationTests: XCTestCase {

    func testARealLibraryComesOverWhole() throws {
        guard let copy = ProcessInfo.processInfo.environment["VEDIVOX_LIBRARY_COPY"] else {
            throw XCTSkip("set TEST_RUNNER_VEDIVOX_LIBRARY_COPY to a copy of a library")
        }
        let base = URL(fileURLWithPath: copy, isDirectory: true)
        let legacy = base.appendingPathComponent(LegacyNames.dataDirectoryName, isDirectory: true)
        let current = base.appendingPathComponent("Vedivox", isDirectory: true)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent(LegacyNames.databaseFileName).path), "no copy at \(legacy.path)")
        XCTAssertFalse(fm.fileExists(atPath: current.path), "\(current.path) is left from an earlier run — make a fresh copy")

        // The old app still running: it holds the lock, nothing moves.
        let lock = Darwin.open(DataDirectoryLock.lockFileURL(in: legacy).path, O_CREAT | O_RDWR, 0o644)
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        guard case .inUse = DataDirectoryMigration.move(from: legacy, to: current) else {
            return XCTFail("a held library must not move")
        }
        Darwin.close(lock)
        XCTAssertTrue(fm.fileExists(atPath: legacy.path))

        // A second library under the new name: used as it is, nothing merged.
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: current.appendingPathComponent("marker"))
        XCTAssertEqual(DataDirectoryMigration.move(from: legacy, to: current), .bothExist)
        XCTAssertTrue(fm.fileExists(atPath: legacy.path))
        try fm.removeItem(at: current)

        // The move itself.
        let started = Date()
        XCTAssertEqual(DataDirectoryMigration.move(from: legacy, to: current), .moved)
        let moveSeconds = Date().timeIntervalSince(started)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))

        // The files inside.
        XCTAssertEqual(DataDirectoryMigration.renameFiles(in: current), .moved)
        let database = current.appendingPathComponent("Vedivox.sqlite")
        XCTAssertTrue(fm.fileExists(atPath: database.path))
        XCTAssertFalse(fm.fileExists(atPath: current.appendingPathComponent(LegacyNames.databaseFileName).path))
        XCTAssertEqual(DataDirectoryMigration.renameFiles(in: current), .nothingToMove, "a second launch finds nothing to do")

        // The stored paths, through the real migrator.
        let old = DataDirectoryMigration.legacyProduction.path + "/"
        let new = DataDirectory.production.path + "/"
        let queue = try DatabaseQueue(path: database.path)
        func count(_ prefix: String) throws -> Int {
            try queue.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM meetings WHERE substr(micAudioPath, 1, length(?1)) = ?1
                    OR substr(systemAudioPath, 1, length(?1)) = ?1 OR substr(sourceFilePath, 1, length(?1)) = ?1
                    """, arguments: [prefix]) ?? 0
            }
        }
        // Rows a migration may drop: empty unedited lines (v25) and the
        // meeting_speakers links reconciled after them. Everything else stays.
        let kept = ["meetings", "speakers", "dictations", "meeting_marks", "meeting_series"]
        func rows(_ table: String) throws -> Int {
            try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") ?? 0 }
        }
        let rowsBefore = try Dictionary(uniqueKeysWithValues: kept.map { ($0, try rows($0)) })
        let meetingsBefore = rowsBefore["meetings"] ?? 0
        let emptyLines = try queue.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM transcript_segments WHERE trim(text) = '' AND isEdited = 0") ?? 0
        }
        let linesBefore = try rows("transcript_segments")
        let underOld = try count(old)
        let applied = try queue.read { try DatabaseManager.migrator.appliedMigrations($0) }
        let backupsBefore = try fm.contentsOfDirectory(atPath: current.appendingPathComponent("backups").path)
        // As the app opens it: a copy of the database first, then the migrations.
        try DatabaseSafety.update(
            queue, migrator: DatabaseManager.migrator, databasePath: database.path, dataDirectory: current, report: { _ in }
        )
        for table in kept { XCTAssertEqual(try rows(table), rowsBefore[table], table) }
        XCTAssertEqual(try rows("transcript_segments"), linesBefore - emptyLines)
        XCTAssertEqual(try count(old), 0, "no path is left in the old directory")
        XCTAssertEqual(try count(new), underOld, "every one of them is in the new directory")
        let backups = try fm.contentsOfDirectory(atPath: current.appendingPathComponent("backups").path)
        let first = DatabaseManager.migrator.migrations.first { !applied.contains($0) } ?? "-"
        let copyBefore = backups.filter { !backupsBefore.contains($0) && $0.hasSuffix("-before-\(first).sqlite") }
        XCTAssertEqual(copyBefore.count, 1, "one automatic copy before \(first): \(backups)")
        XCTAssertTrue(Set(backupsBefore).isSubset(of: backups), "the old build's copies survive the first rotation")

        // Every row reads back through the app's own types.
        let decoded = try queue.read { db in
            [
                try Meeting.fetchCount(db), try Meeting.fetchAll(db).count, try TranscriptSegment.fetchAll(db).count,
                try Speaker.fetchAll(db).count, try MeetingSpeaker.fetchAll(db).count, try Dictation.fetchAll(db).count,
                try MeetingMark.fetchAll(db).count, try MeetingSeries.fetchAll(db).count,
            ]
        }
        XCTAssertEqual(decoded[0], decoded[1])
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM meetings WHERE status = 'extracting'") }, 0)
        try queue.write { db in try db.execute(sql: "INSERT INTO transcript_fts(transcript_fts) VALUES ('integrity-check')") }

        // A meeting whose audio came along in the copy plays from its new path.
        let audio: [String] = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT micAudioPath FROM meetings WHERE micAudioPath IS NOT NULL")
        }
        let present = audio.map { current.path + "/" + String($0.dropFirst(new.count)) }.filter { fm.fileExists(atPath: $0) }
        XCTAssertFalse(present.isEmpty, "none of the copied audio is found under the rewritten paths")

        // The settings, into a throwaway domain.
        let plist = base.appendingPathComponent("legacy-defaults.plist")
        let legacySettings = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let suite = "vedivox-copy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let carried = try XCTUnwrap(LegacySettings.adopt(into: defaults, domain: suite, legacy: legacySettings))
        XCTAssertEqual(carried, legacySettings.count - LegacySettings.leftBehind.filter { legacySettings[$0] != nil }.count)
        XCTAssertFalse(defaults.bool(forKey: "onboardingCompleted"))
        // The palette view (not in this target) reads an old stored value through this table.
        let palette = defaults.string(forKey: "voxPalette")
        if let palette { XCTAssertNotNil(LegacyNames.paletteRawValues[palette] ?? (["mono", "ink"].contains(palette) ? palette : nil)) }

        print("""
            library copy: moved in \(String(format: "%.3f", moveSeconds)) s; \(meetingsBefore) meetings; \
            \(underOld) with paths in the old directory, all rewritten; \(present.count) of \(audio.count) audio files \
            present in the copy found at their new paths; migrations applied before: \(applied.count), \
            copy taken before \(first); rows kept: \(rowsBefore.sorted { $0.key < $1.key }); lines \(linesBefore) → \
            \(linesBefore - emptyLines); decoded: \(decoded); \
            settings carried: \(carried) of \(legacySettings.count); palette: \
            \(palette ?? "-") → \(palette.map { LegacyNames.paletteRawValues[$0] ?? $0 } ?? "-")
            """)
    }
}
