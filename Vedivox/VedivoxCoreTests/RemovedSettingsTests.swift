import XCTest

/// Settings removed by the settings review: their keys stay in
/// users' defaults, untouched. A stored value must stay inert — no reader
/// left to trip over it at launch or in Settings. Telemetry and Crash reports
/// never had a key, so they need no case here.
final class RemovedSettingsTests: XCTestCase {
    private nonisolated(unsafe) static let removedKeys: [String: Any] = [
        "defaultLanguage": "ru",
        "recordMicrophone": false,
        "recordSystemAudio": false,
        "voxDensity": "cozy",
    ]

    func testNoViewReadsARemovedKey() throws {
        // Bundled as a folder resource (project.yml), like DesignSystemLiteralTests.
        let views = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Views", withExtension: nil))
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for key in Self.removedKeys.keys {
                XCTAssertFalse(source.contains("\"\(key)\""), "\(file.lastPathComponent) reads the removed key \(key)")
            }
        }
    }

    /// The first thing AppState.init does with defaults, on an install that
    /// still carries the old values.
    func testOldValuesLeaveTheLaunchMigrationAlone() {
        let suite = "RemovedSettingsTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setValuesForKeys(Self.removedKeys)
        defaults.set(true, forKey: "onboardingCompleted")

        PreviousDefaults.pinIfNeeded(defaults)

        XCTAssertEqual(defaults.string(forKey: "voxPalette"), "ink")
        XCTAssertEqual(defaults.string(forKey: "defaultLanguage"), "ru", "a removed key is left as it was")
    }
}
