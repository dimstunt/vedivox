import GRDB
import XCTest

/// The library of someone who used the app under its old name has to arrive
/// under the new one whole, or not move at all. Every case here ends by
/// checking that what was on disk is still on disk.
final class DataDirectoryMigrationTests: XCTestCase {

    private var base: URL!
    private var legacy: URL { base.appendingPathComponent("Vox", isDirectory: true) }
    private var current: URL { base.appendingPathComponent("Vedivox", isDirectory: true) }

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vox-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func write(_ text: String, _ relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relative: String, in root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A library as the old app left it.
    private func makeLegacyLibrary() throws {
        try write("database", "Vox.sqlite", in: legacy)
        try write("mic", "audio/M1/mic.m4a", in: legacy)
        try write("log", "logs/vox.log", in: legacy)
    }

    // MARK: - The Directory

    func testLibraryMovesWhole() throws {
        try makeLegacyLibrary()

        XCTAssertEqual(DataDirectoryMigration.move(from: legacy, to: current), .moved)

        XCTAssertFalse(exists(legacy), "one rename: nothing stays under the old name")
        XCTAssertEqual(read("Vox.sqlite", in: current), "database")
        XCTAssertEqual(read("audio/M1/mic.m4a", in: current), "mic")
        XCTAssertEqual(read("logs/vox.log", in: current), "log")
    }

    func testNothingHappensWithoutALibraryUnderTheOldName() {
        XCTAssertEqual(DataDirectoryMigration.move(from: legacy, to: current), .nothingToMove)
        XCTAssertFalse(exists(current), "a new install's directory is not this code's to create")
    }

    func testALibraryAlreadyMovedIsLeftAlone() throws {
        try write("database", "Vedivox.sqlite", in: current)

        XCTAssertEqual(DataDirectoryMigration.move(from: legacy, to: current), .nothingToMove)
        XCTAssertEqual(read("Vedivox.sqlite", in: current), "database")
    }

    func testTwoLibrariesAreNeverMerged() throws {
        try makeLegacyLibrary()
        try write("newer database", "Vedivox.sqlite", in: current)

        XCTAssertEqual(DataDirectoryMigration.move(from: legacy, to: current), .bothExist)

        XCTAssertEqual(read("Vox.sqlite", in: legacy), "database", "the old library stays where it is")
        XCTAssertEqual(read("audio/M1/mic.m4a", in: legacy), "mic")
        XCTAssertEqual(read("Vedivox.sqlite", in: current), "newer database", "and the new one is not written over")
        XCTAssertNil(read("Vox.sqlite", in: current))
    }

    func testAnEmptyDirectoryUnderTheNewNameIsNotASecondLibrary() throws {
        try makeLegacyLibrary()
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

        XCTAssertEqual(DataDirectoryMigration.move(from: legacy, to: current), .moved)
        XCTAssertEqual(read("Vox.sqlite", in: current), "database")
    }

    /// `flock` conflicts across descriptors within one process, so a claim
    /// taken here stands in for the old app still running.
    func testALibraryTheOldAppHoldsStaysWhereItIs() throws {
        try makeLegacyLibrary()
        let holder = DataDirectoryHolder(pid: 4242, bundlePath: "/Applications/Vox.app", startedAt: Date())
        guard case .acquired(let lock) = DataDirectoryLock.acquire(in: legacy, holder: holder) else {
            return XCTFail("could not stand in for the running old app")
        }
        defer { lock.release() }

        guard case .inUse(let reported) = DataDirectoryMigration.move(from: legacy, to: current) else {
            return XCTFail("the library was moved from under a running app")
        }

        XCTAssertEqual(reported?.pid, 4242, "the refusal names who holds the library")
        XCTAssertEqual(read("Vox.sqlite", in: legacy), "database")
        XCTAssertFalse(exists(current))
    }

    func testARefusedRenameLeavesEverythingInPlace() throws {
        try makeLegacyLibrary()
        let otherVolume: DataDirectoryMigration.Rename = { _, _ in
            errno = EXDEV
            return -1
        }

        guard case .failed(let reason) = DataDirectoryMigration.move(from: legacy, to: current, rename: otherVolume) else {
            return XCTFail("a refused rename was not reported")
        }

        XCTAssertTrue(reason.contains(legacy.path), "the reason says which library: \(reason)")
        XCTAssertEqual(read("Vox.sqlite", in: legacy), "database")
        XCTAssertEqual(read("audio/M1/mic.m4a", in: legacy), "mic")
        XCTAssertFalse(exists(current), "nothing was copied instead")

        // And the lock taken for the attempt is not left behind.
        guard case .acquired(let lock) = DataDirectoryLock.acquire(in: legacy) else {
            return XCTFail("the failed move still holds the library")
        }
        lock.release()
    }

    // MARK: - The Files Inside

    func testFilesGetTheirNewNames() throws {
        try write("database", "Vox.sqlite", in: current)
        try write("wal", "Vox.sqlite-wal", in: current)
        try write("shm", "Vox.sqlite-shm", in: current)
        try write("log", "logs/vox.log", in: current)
        try write("older log", "logs/vox.1.log", in: current)
        try write("mic", "audio/M1/mic.m4a", in: current)

        XCTAssertEqual(DataDirectoryMigration.renameFiles(in: current), .moved)

        XCTAssertEqual(read("Vedivox.sqlite", in: current), "database")
        XCTAssertEqual(read("Vedivox.sqlite-wal", in: current), "wal", "the write-ahead log follows its database")
        XCTAssertEqual(read("Vedivox.sqlite-shm", in: current), "shm")
        XCTAssertEqual(read("logs/vedivox.log", in: current), "log")
        XCTAssertEqual(read("logs/vedivox.1.log", in: current), "older log")
        XCTAssertEqual(read("audio/M1/mic.m4a", in: current), "mic")
        for old in ["Vox.sqlite", "Vox.sqlite-wal", "Vox.sqlite-shm", "logs/vox.log", "logs/vox.1.log"] {
            XCTAssertNil(read(old, in: current), old)
        }

        XCTAssertEqual(DataDirectoryMigration.renameFiles(in: current), .nothingToMove, "the second launch finds nothing to do")
    }

    func testAFreshInstallIsNotTouched() {
        XCTAssertEqual(DataDirectoryMigration.renameFiles(in: current), .nothingToMove)
        XCTAssertFalse(exists(current))
    }

    /// The log went first and the run was cut before the database followed.
    func testARunCutShortIsFinishedByTheNextOne() throws {
        try write("wal", "Vedivox.sqlite-wal", in: current)
        try write("database", "Vox.sqlite", in: current)

        XCTAssertEqual(DataDirectoryMigration.renameFiles(in: current), .moved)

        XCTAssertEqual(read("Vedivox.sqlite", in: current), "database")
        XCTAssertEqual(read("Vedivox.sqlite-wal", in: current), "wal")
    }

    /// A database under each name: the write-ahead log of the old one must not
    /// end up beside the new one, where SQLite would replay it into the wrong file.
    func testTwoDatabasesKeepTheirOwnFiles() throws {
        try write("old database", "Vox.sqlite", in: current)
        try write("old wal", "Vox.sqlite-wal", in: current)
        try write("new database", "Vedivox.sqlite", in: current)

        XCTAssertEqual(DataDirectoryMigration.renameFiles(in: current), .nothingToMove)

        XCTAssertEqual(read("Vox.sqlite", in: current), "old database")
        XCTAssertEqual(read("Vox.sqlite-wal", in: current), "old wal")
        XCTAssertEqual(read("Vedivox.sqlite", in: current), "new database")
        XCTAssertNil(read("Vedivox.sqlite-wal", in: current))
    }

    func testADatabaseThatCannotBeRenamedStopsTheLaunch() throws {
        try write("database", "Vox.sqlite", in: current)
        let refusing: DataDirectoryMigration.Rename = { _, _ in
            errno = EACCES
            return -1
        }

        guard case .failed(let reason) = DataDirectoryMigration.renameFiles(in: current, rename: refusing) else {
            return XCTFail("the app would have started an empty database beside the real one")
        }
        XCTAssertTrue(reason.contains("Vox.sqlite"), reason)
        XCTAssertEqual(read("Vox.sqlite", in: current), "database")
    }

    func testADirectoryInUseIsLeftToItsOwner() throws {
        try write("database", "Vox.sqlite", in: current)
        guard case .acquired(let lock) = DataDirectoryLock.acquire(in: current) else {
            return XCTFail("could not stand in for a running instance")
        }
        defer { lock.release() }

        guard case .inUse = DataDirectoryMigration.renameFiles(in: current) else {
            return XCTFail("files were renamed under a running instance")
        }
        XCTAssertEqual(read("Vox.sqlite", in: current), "database")
    }

    // MARK: - The Paths In The Database

    /// The whole road a real library takes: a database from the last build
    /// under the old name, with the absolute paths that build wrote.
    func testMigrationPointsStoredPathsAtTheNewDirectory() throws {
        let old = DataDirectoryMigration.legacyProduction.path
        let new = DataDirectory.production.path
        XCTAssertTrue(old.hasSuffix("/Application Support/Vox"), old)
        XCTAssertTrue(new.hasSuffix("/Application Support/Vedivox"), new)

        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v26-speaker-verdicts")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (id, title, startTime, micAudioPath, systemAudioPath, sourceFilePath) VALUES
                ('recorded', 'recorded', '2026-01-01', ?, ?, NULL),
                ('imported', 'imported', '2026-01-02', ?, NULL, ?),
                ('elsewhere', 'elsewhere', '2026-01-03', ?, NULL, ?)
                """, arguments: [
                    "\(old)/audio/recorded/mic.m4a", "\(old)/audio/recorded/system.m4a",
                    "\(old)/audio/imported/mic.m4a", "/Users/someone/Downloads/talk.mp4",
                    "/Volumes/Backup\(old)/audio/elsewhere/mic.m4a", "\(old)-copy/talk.mp4",
                ])
        }

        try DatabaseManager.migrator.migrate(queue)

        let paths: [String: [String?]] = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, micAudioPath, systemAudioPath, sourceFilePath FROM meetings")
                .reduce(into: [:]) { $0[$1["id"] as String] = [$1["micAudioPath"], $1["systemAudioPath"], $1["sourceFilePath"]] }
        }
        XCTAssertEqual(paths["recorded"], ["\(new)/audio/recorded/mic.m4a", "\(new)/audio/recorded/system.m4a", nil])
        XCTAssertEqual(paths["imported"], ["\(new)/audio/imported/mic.m4a", nil, "/Users/someone/Downloads/talk.mp4"],
                       "a file outside the library is where it always was")
        XCTAssertEqual(paths["elsewhere"], ["/Volumes/Backup\(old)/audio/elsewhere/mic.m4a", nil, "\(old)-copy/talk.mp4"],
                       "only a path that starts in the old directory is in the library")
    }

    func testRewritingPathsTwiceChangesNothingMore() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (id, title, startTime, micAudioPath) VALUES ('m', 'm', '2026-01-01', '/data/Vox/audio/m/mic.m4a')
                """)
            try DataDirectoryMigration.rewriteStoredPaths(db, from: "/data/Vox", to: "/data/Vedivox")
            try DataDirectoryMigration.rewriteStoredPaths(db, from: "/data/Vox", to: "/data/Vedivox")
        }
        let path = try queue.read { try String.fetchOne($0, sql: "SELECT micAudioPath FROM meetings") }
        XCTAssertEqual(path, "/data/Vedivox/audio/m/mic.m4a")
    }

    // MARK: - Settings

    func testSettingsComeOverExceptOnboarding() {
        let legacy: [String: Any] = [
            "KeyboardShortcuts_dictation": "{\"carbonKeyCode\":49}",
            "selectedMicDeviceUID": "BuiltInMicrophoneDevice",
            "voxPalette": "dimstunt",
            "voxTheme": "light",
            "meetingDetectionEnabled": true,
            "onboardingCompleted": true,
        ]

        let carried = LegacySettings.carriedOver(from: legacy, into: ["voxTheme": "dark"])

        XCTAssertEqual(carried["KeyboardShortcuts_dictation"] as? String, "{\"carbonKeyCode\":49}")
        XCTAssertEqual(carried["selectedMicDeviceUID"] as? String, "BuiltInMicrophoneDevice")
        XCTAssertEqual(carried["voxPalette"] as? String, "dimstunt")
        XCTAssertEqual(carried["meetingDetectionEnabled"] as? Bool, true)
        XCTAssertNil(carried["voxTheme"], "a setting already made under the new name wins")
        XCTAssertNil(carried["onboardingCompleted"], "the permissions are gone with the identifier: onboarding walks through them again")
    }

    func testSettingsAreAdoptedOnce() throws {
        let suite = "legacy-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(LegacySettings.adopt(into: defaults, domain: suite, legacy: ["defaultLanguage": "en", "onboardingCompleted": true]), 1)
        XCTAssertEqual(defaults.string(forKey: "defaultLanguage"), "en")
        XCTAssertFalse(defaults.bool(forKey: "onboardingCompleted"))

        defaults.set("ru", forKey: "defaultLanguage")
        XCTAssertNil(LegacySettings.adopt(into: defaults, domain: suite, legacy: ["defaultLanguage": "de", "seekStepSeconds": 5]))
        XCTAssertEqual(defaults.string(forKey: "defaultLanguage"), "ru", "the old domain is not consulted a second time")
        XCTAssertNil(defaults.object(forKey: "seekStepSeconds"))
    }

    func testAFirstLaunchWithNoOldSettingsStillCountsAsTheLook() throws {
        let suite = "legacy-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(LegacySettings.adopt(into: defaults, domain: suite, legacy: nil), 0)
        XCTAssertNil(LegacySettings.adopt(into: defaults, domain: suite, legacy: ["defaultLanguage": "en"]))
    }
}
