import XCTest

/// Pins the data-directory contract: one resolver, configurable, and nothing
/// keeping a path of its own.
///
/// Before an earlier change the path was spelled out
/// independently in six places, so pointing a build at a copy of the data was
/// guaranteed to miss one of them and write into the live directory anyway.
final class DataDirectoryTests: XCTestCase {

    // MARK: - Resolution

    func testEnvironmentVariableSelectsTheDirectory() {
        let resolved = DataDirectory.resolve(
            environment: [DataDirectory.environmentKey: "/tmp/vedivox-debug"],
            arguments: []
        )
        XCTAssertEqual(resolved.path, "/tmp/vedivox-debug")
    }

    func testCommandLineArgumentSelectsTheDirectory() {
        let resolved = DataDirectory.resolve(
            environment: [:],
            arguments: ["Vedivox", DataDirectory.argumentKey, "/tmp/vedivox-from-argument"]
        )
        XCTAssertEqual(resolved.path, "/tmp/vedivox-from-argument")
    }

    /// A scheme can carry both; the per-launch argument is the more specific
    /// statement of intent.
    func testArgumentWinsOverEnvironment() {
        let resolved = DataDirectory.resolve(
            environment: [DataDirectory.environmentKey: "/tmp/vedivox-from-environment"],
            arguments: ["Vedivox", DataDirectory.argumentKey, "/tmp/vedivox-from-argument"]
        )
        XCTAssertEqual(resolved.path, "/tmp/vedivox-from-argument")
    }

    func testUnconfiguredResolvesToProduction() {
        let resolved = DataDirectory.resolve(environment: [:], arguments: ["Vedivox"])
        XCTAssertEqual(resolved.standardizedFileURL, DataDirectory.production.standardizedFileURL)
        XCTAssertEqual(resolved.lastPathComponent, DataDirectory.productionDirectoryName)
    }

    func testTildeIsExpanded() {
        let resolved = DataDirectory.resolve(
            environment: [DataDirectory.environmentKey: "~/vedivox-copy"],
            arguments: []
        )
        XCTAssertFalse(resolved.path.contains("~"))
        XCTAssertTrue(resolved.path.hasSuffix("/vedivox-copy"))
    }

    /// A blank value is a misconfiguration, not a request to use the filesystem
    /// root — falling back to production is the only safe reading.
    func testBlankConfigurationIsIgnored() {
        for blank in ["", "   "] {
            XCTAssertEqual(
                DataDirectory.resolve(environment: [DataDirectory.environmentKey: blank], arguments: []).standardizedFileURL,
                DataDirectory.production.standardizedFileURL,
                "blank environment value \(blank.debugDescription) should fall back to production"
            )
            XCTAssertEqual(
                DataDirectory.resolve(environment: [:], arguments: ["Vedivox", DataDirectory.argumentKey, blank]).standardizedFileURL,
                DataDirectory.production.standardizedFileURL,
                "blank argument value \(blank.debugDescription) should fall back to production"
            )
        }
    }

    /// The flag with nothing after it must not read past the end of the array.
    func testArgumentWithoutValueIsIgnored() {
        let resolved = DataDirectory.resolve(environment: [:], arguments: ["Vedivox", DataDirectory.argumentKey])
        XCTAssertEqual(resolved.standardizedFileURL, DataDirectory.production.standardizedFileURL)
    }

    // MARK: - Tests Stay Off The Live Directory

    /// Every `make test` used to write its temporary lock and socket paths into
    /// the user's real log, because the log resolves through here and a test
    /// process asks for no directory in particular.
    func testUnconfiguredTestProcessAvoidsProduction() {
        let resolved = DataDirectory.resolve(
            environment: ["XCTestConfigurationFilePath": "/tmp/whatever.xctestconfiguration"],
            arguments: ["xctest"]
        )

        XCTAssertNotEqual(resolved.standardizedFileURL, DataDirectory.production.standardizedFileURL)
        XCTAssertEqual(resolved.lastPathComponent, DataDirectory.testDirectoryName)
        XCTAssertFalse(
            resolved.standardizedFileURL.path.hasPrefix(DataDirectory.production.standardizedFileURL.path + "/"),
            "the test directory must be a sibling of the live one, not a child"
        )
    }

    func testSessionIdentifierAlsoMarksATestProcess() {
        let resolved = DataDirectory.resolve(
            environment: ["XCTestSessionIdentifier": "ABC"],
            arguments: ["xctest"]
        )
        XCTAssertEqual(resolved.lastPathComponent, DataDirectory.testDirectoryName)
    }

    /// A test that asks for a directory gets exactly that one — the fallback
    /// must not override an explicit choice.
    func testExplicitDirectoryWinsInsideATestProcess() {
        let resolved = DataDirectory.resolve(
            environment: [
                "XCTestConfigurationFilePath": "/tmp/whatever.xctestconfiguration",
                DataDirectory.environmentKey: "/tmp/vedivox-explicit",
            ],
            arguments: []
        )
        XCTAssertEqual(resolved.path, "/tmp/vedivox-explicit")
    }

    /// This suite runs inside XCTest, so the live directory must not be in use.
    func testThisRunIsNotUsingTheLiveDirectory() {
        XCTAssertNotEqual(
            DataDirectory.root.standardizedFileURL,
            DataDirectory.production.standardizedFileURL,
            "a test run resolved to the production data directory"
        )
    }

    // MARK: - Everything Derives From The Root

    private func assertIsUnderRoot(_ url: URL, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let root = DataDirectory.root.standardizedFileURL.path
        XCTAssertTrue(
            url.standardizedFileURL.path.hasPrefix(root + "/"),
            "\(label) resolved to \(url.path), which is outside the data directory \(root)",
            file: file,
            line: line
        )
    }

    func testAllDataKindsLiveUnderTheResolvedRoot() {
        assertIsUnderRoot(DataDirectory.audio, "meeting audio")
        assertIsUnderRoot(DataDirectory.dictations, "dictation audio")
        assertIsUnderRoot(DataDirectory.logs, "logs")
        assertIsUnderRoot(DataDirectory.vocabulary, "vocabulary")
    }

    /// The meeting audio path must have no source of its own — this is what
    /// broke the previous attempts to run on a copy of the data.
    func testMeetingAudioDirectoryDerivesFromTheRoot() {
        let directory = DatabaseManager.audioDirectoryURL(for: "meeting-id")
        assertIsUnderRoot(directory, "meeting audio directory")
        XCTAssertEqual(directory.lastPathComponent, "meeting-id")
        XCTAssertEqual(
            directory.deletingLastPathComponent().standardizedFileURL,
            DataDirectory.audio.standardizedFileURL
        )
    }

    /// An explicit root still overrides — the benchmark relies on it to keep
    /// intermediate WAVs out of the real audio folder.
    func testExplicitRootStillOverridesTheMeetingAudioDirectory() {
        let override = URL(fileURLWithPath: "/tmp/vedivox-bench", isDirectory: true)
        let directory = DatabaseManager.audioDirectoryURL(for: "meeting-id", root: override)
        XCTAssertEqual(directory.path, "/tmp/vedivox-bench/meeting-id")
    }

    func testLogDirectoryDerivesFromTheRoot() {
        assertIsUnderRoot(Log.logDirectory, "log directory")
        XCTAssertEqual(Log.logDirectory.standardizedFileURL, DataDirectory.logs.standardizedFileURL)
    }

    func testVocabularyDirectoryDerivesFromTheRoot() {
        assertIsUnderRoot(TermNormalizer.vocabularyDirectory, "vocabulary directory")
        XCTAssertEqual(
            TermNormalizer.vocabularyDirectory.standardizedFileURL,
            DataDirectory.vocabulary.standardizedFileURL
        )
    }
}
