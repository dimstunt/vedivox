import XCTest

final class PreviousDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PreviousDefaultsTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testExistingInstallKeepsTheOldDefaults() {
        defaults.set(true, forKey: "onboardingCompleted")
        PreviousDefaults.pinIfNeeded(defaults)
        XCTAssertEqual(defaults.string(forKey: "voxPalette"), "ink")
        XCTAssertEqual(SystemCaptureExclusions.load(defaults), ["com.obsproject.obs-studio", "com.cmuxterm.app"])
    }

    func testAnInstallFromVoxKeepsTheOldDefaults() {
        // Onboarding was finished under the old name; the flag did not come over.
        PreviousDefaults.pinIfNeeded(defaults, legacy: ["onboardingCompleted": true])
        XCTAssertEqual(defaults.string(forKey: "voxPalette"), "ink")
        XCTAssertEqual(SystemCaptureExclusions.load(defaults), ["com.obsproject.obs-studio", "com.cmuxterm.app"])
    }

    func testAChoiceMadeBeforeIsKept() {
        defaults.set(true, forKey: "onboardingCompleted")
        defaults.set("mono", forKey: "voxPalette")
        defaults.set("[]", forKey: SystemCaptureExclusions.defaultsKey)
        PreviousDefaults.pinIfNeeded(defaults)
        XCTAssertEqual(defaults.string(forKey: "voxPalette"), "mono")
        XCTAssertEqual(SystemCaptureExclusions.load(defaults), [])
    }

    func testNewInstallGetsTheNewDefaultsForGood() {
        PreviousDefaults.pinIfNeeded(defaults)
        // Onboarding finishes, the app relaunches: still nothing pinned.
        defaults.set(true, forKey: "onboardingCompleted")
        PreviousDefaults.pinIfNeeded(defaults)
        XCTAssertNil(defaults.object(forKey: "voxPalette"))
        XCTAssertEqual(SystemCaptureExclusions.load(defaults), ["com.obsproject.obs-studio"])
    }
}
