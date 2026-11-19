import XCTest

final class SystemCaptureExclusionsTests: XCTestCase {
    private let list = ["com.obsproject.obs-studio", "com.cmuxterm.app"]

    func testMatchesExactHelperAndCase() {
        XCTAssertEqual(SystemCaptureExclusions.entry(matching: "com.obsproject.obs-studio", in: list), "com.obsproject.obs-studio")
        XCTAssertEqual(SystemCaptureExclusions.entry(matching: "com.cmuxterm.app.helper", in: list), "com.cmuxterm.app")
        XCTAssertEqual(SystemCaptureExclusions.entry(matching: "com.OBSProject.OBS-Studio", in: list), "com.obsproject.obs-studio")
    }

    func testDoesNotMatchSiblingPrefix() {
        XCTAssertNil(SystemCaptureExclusions.entry(matching: "com.cmuxterm.application", in: list))
        XCTAssertNil(SystemCaptureExclusions.entry(matching: "us.zoom.xos", in: list))
        XCTAssertNil(SystemCaptureExclusions.entry(matching: "", in: list))
    }

    func testMissingKeyGivesDefaultsAndRemovalSticks() throws {
        // Unique per run: a fixed name is shared with every parallel test process.
        let suite = "SystemCaptureExclusionsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SystemCaptureExclusions.load(defaults), SystemCaptureExclusions.defaultBundleIDs)

        defaults.set(SystemCaptureExclusions.encode(["com.obsproject.obs-studio"]), forKey: SystemCaptureExclusions.defaultsKey)
        XCTAssertEqual(SystemCaptureExclusions.load(defaults), ["com.obsproject.obs-studio"])

        defaults.set("[]", forKey: SystemCaptureExclusions.defaultsKey)
        XCTAssertEqual(SystemCaptureExclusions.load(defaults), [])
    }
}
