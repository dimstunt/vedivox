import SQLite3
import XCTest

/// Smoke tests over the main paths of the main window (`make test-smoke`).
///
/// Every test launches the Debug app on its own copy of a seeded data
/// directory (`VEDIVOX_DATA_DIR`), so nothing reaches the user's live data. The
/// seed is built once per run: the app is launched on an empty directory to
/// create the database with its own migrations, then three meetings are
/// inserted with SQLite — the schema always matches the build under test.
final class SmokeUITests: XCTestCase {
    private static let alphaId = "AAAAAAAA-0000-0000-0000-000000000001"
    private static let alphaTitle = "Alpha Planning Sync"
    private static let betaTitle = "Beta Retro"
    private static let gammaTitle = "Gamma Rename Target"

    /// Built by the first test that needs it, then copied per test.
    private static var seedDirectory: URL?

    private var app: XCUIApplication!
    private var dataDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let seed = try Self.seed()
        dataDirectory = try Self.makeDirectory()
        for item in try FileManager.default.contentsOfDirectory(at: seed, includingPropertiesForKeys: nil)
            where item.lastPathComponent.contains("sqlite") {
            try FileManager.default.copyItem(at: item, to: dataDirectory.appendingPathComponent(item.lastPathComponent))
        }
        app = Self.launch(dataDirectory)
    }

    override class func tearDown() {
        if let seedDirectory { try? FileManager.default.removeItem(at: seedDirectory) }
        seedDirectory = nil
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let dataDirectory { try? FileManager.default.removeItem(at: dataDirectory) }
    }

    // MARK: - Tests

    /// 1. The seeded list shows up, and nothing is selected yet.
    func testLaunchShowsMeetingListAndEmptyDetail() {
        XCTAssertTrue(app.staticTexts["No Meeting Selected"].waitForExistence(timeout: 15))
        XCTAssertTrue(row(Self.alphaTitle).exists)
        XCTAssertTrue(row(Self.betaTitle).exists)
        XCTAssertTrue(row(Self.gammaTitle).exists)
    }

    /// 2. Picking a meeting opens its transcript, and → reaches the player
    /// (the focus bug of 2026-10-02: keys were dead after a selection).
    func testSelectingMeetingGivesPlayerTheKeyboard() {
        openAlpha()
        XCTAssertEqual(currentTime.value as? String, "00:00")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(wait(for: currentTime, valueNot: "00:00"), "→ did not seek after selecting a meeting")
    }

    /// 3. Search filters the list; Esc hands the keyboard back to the player.
    func testSearchFiltersAndEscReturnsKeysToPlayer() {
        openAlpha()
        let search = app.textFields["sidebar.search"]
        search.click()
        search.typeText("Beta")
        XCTAssertTrue(wait(for: meetingRows, count: 1), "search did not filter the list")
        XCTAssertTrue(row(Self.betaTitle).exists)

        app.typeKey(.escape, modifierFlags: [])
        app.typeText("x")
        XCTAssertEqual(search.value as? String, "Beta", "a key after Esc still reached the search field")

        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(wait(for: currentTime, valueNot: "00:00"), "→ did not seek after Esc from search")
    }

    /// 4. Settings → meeting → Back lands on Settings again (one history step).
    func testBackFromMeetingReturnsToSettings() {
        openAlpha()
        app.buttons["sidebar.Settings"].click()
        XCTAssertTrue(app.buttons["settings.section.general"].waitForExistence(timeout: 5))

        row(Self.alphaTitle).click()
        XCTAssertTrue(meetingTitle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.section.general"].exists)

        app.buttons["toolbar.back"].click()
        XCTAssertTrue(app.buttons["settings.section.general"].waitForExistence(timeout: 5), "Back did not return to Settings")
    }

    /// 5. The main Settings sections open; About shows the version.
    func testSettingsSectionsOpen() {
        XCTAssertTrue(row(Self.alphaTitle).waitForExistence(timeout: 15))
        app.buttons["sidebar.Settings"].click()

        let sections = [
            ("general", "APPEARANCE"),
            ("recording", "AUDIO"),
            ("meetings", "MEETING DETECTION"),
            ("transcript", "SPEECH RECOGNITION"),
            ("shortcuts", "PLAYER"),
        ]
        for (section, groupTitle) in sections {
            app.buttons["settings.section.\(section)"].click()
            XCTAssertTrue(app.staticTexts[groupTitle].waitForExistence(timeout: 5), "\(section) did not open")
        }

        app.buttons["settings.section.about"].click()
        let version = app.staticTexts.matching(
            NSPredicate(format: "value MATCHES %@", #"^\d+\.\d+\.\d+ \(\d+\)$"#)
        ).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5), "About shows no version")
    }

    /// 6. Inline rename of the title persists into the list and across a relaunch.
    func testInlineRenamePersists() {
        let newTitle = "Gamma Renamed In Test"
        XCTAssertTrue(row(Self.gammaTitle).waitForExistence(timeout: 15))
        row(Self.gammaTitle).click()
        XCTAssertTrue(meetingTitle.waitForExistence(timeout: 5))
        meetingTitle.click()

        let field = app.textFields["meeting.titleField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        field.typeText(newTitle + "\r")

        XCTAssertTrue(row(newTitle).waitForExistence(timeout: 5), "list did not pick up the new title")
        XCTAssertFalse(row(Self.gammaTitle).exists)

        app.terminate()
        app = Self.launch(dataDirectory)
        XCTAssertTrue(row(newTitle).waitForExistence(timeout: 15), "rename did not survive a relaunch")
    }

    // MARK: - Elements

    private var meetingRows: XCUIElementQuery { app.buttons.matching(identifier: "sidebar.meeting") }
    private var meetingTitle: XCUIElement { app.staticTexts["meeting.title"] }
    private var currentTime: XCUIElement { app.staticTexts["player.currentTime"] }

    private func row(_ title: String) -> XCUIElement {
        meetingRows.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    /// Opens Alpha and waits for its audio: the seed stores 31 s while the file
    /// is 30 s, so `00:30` on the duration label means the player has loaded
    /// the file (before that the label shows the stored 31 s and a seek is a no-op).
    private func openAlpha() {
        XCTAssertTrue(row(Self.alphaTitle).waitForExistence(timeout: 15))
        row(Self.alphaTitle).click()
        XCTAssertTrue(meetingTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(meetingTitle.value as? String, Self.alphaTitle)
        let duration = app.staticTexts["player.duration"]
        XCTAssertTrue(wait(for: duration, valueNot: "00:31"), "audio did not load")
    }

    private func wait(for element: XCUIElement, valueNot value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND value != %@", value)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    private func wait(for query: XCUIElementQuery, count: Int, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "count == %d", count)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: query)], timeout: timeout) == .completed
    }

    // MARK: - Launch and seed

    /// Launch arguments land in the volatile argument domain, so they override
    /// the user's defaults for this process without writing them: no welcome
    /// wizard, no meeting detection (it would ask browsers for their tabs).
    private static func launch(_ directory: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VEDIVOX_DATA_DIR"] = directory.path
        app.launchArguments += [
            "-onboardingCompleted", "YES",
            "-meetingDetectionEnabled", "NO",
            "-inspectorOpen", "YES",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    /// Short path on purpose: the command socket lives in the data directory,
    /// and a Unix socket path is capped at 104 bytes.
    private static func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vedivox-ui-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func seed() throws -> URL {
        if let seedDirectory { return seedDirectory }
        let directory = try makeDirectory()

        // Let the app create and migrate the database, then quit it.
        let app = launch(directory)
        XCTAssertTrue(app.staticTexts["No Meeting Selected"].waitForExistence(timeout: 30), "app did not start")
        app.terminate()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard let dbName = names.first(where: { $0.hasSuffix(".sqlite") }) else {
            throw SeedError(message: "no database in \(directory.path): \(names)")
        }

        let audio = directory.appendingPathComponent("audio/\(alphaId)", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let mic = audio.appendingPathComponent("mic.wav")
        let fixture = try XCTUnwrap(Bundle(for: SmokeUITests.self).url(forResource: "test_mic_30s", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: mic)

        try execute(directory.appendingPathComponent(dbName).path, sql: """
            INSERT INTO meetings (id, title, startTime, durationSeconds, language, source, micAudioPath, status)
            VALUES
              ('\(alphaId)', '\(alphaTitle)', '2026-09-30 10:00:00.000', 31, 'en', 'recording', '\(mic.path)', 'done'),
              ('BBBBBBBB-0000-0000-0000-000000000002', '\(betaTitle)', '2026-09-29 11:00:00.000', 60, 'en', 'recording', NULL, 'done'),
              ('CCCCCCCC-0000-0000-0000-000000000003', '\(gammaTitle)', '2026-09-28 12:00:00.000', 45, 'en', 'recording', NULL, 'done');
            INSERT INTO transcript_segments (meetingId, speakerLabel, source, startTime, endTime, text)
            VALUES
              ('\(alphaId)', 'SPEAKER_0', 'mic', 0, 10, 'Quarterly roadmap walkthrough'),
              ('\(alphaId)', 'SPEAKER_1', 'mic', 10, 25, 'Budget numbers look fine');
            """)
        seedDirectory = directory
        return directory
    }

    private static func execute(_ path: String, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw SeedError(message: "cannot open \(path)") }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SeedError(message: "seed failed: \(message)")
        }
    }

    private struct SeedError: Error {
        let message: String
    }
}
