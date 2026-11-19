import XCTest

/// The stored-choice rules for the live-recogniser chunk size.
///
/// Worth pinning because the failure mode is silent: a bad stored value must
/// degrade to the default, not leave dictation without live text.
final class DictationChunkSizeTests: XCTestCase {

    private var defaults: UserDefaults!
    // Unique per run: one fixed name is one domain for every xctest process on
    // the machine, and a parallel `make test` in another worktree rewrites it.
    private let suiteName = "DictationChunkSizeTests-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultWhenNothingStored() {
        XCTAssertEqual(DictationChunkSize.stored(in: defaults), .default)
        XCTAssertEqual(DictationChunkSize.default, .ms2240)
    }

    func testRoundTrip() {
        for size in DictationChunkSize.allCases {
            size.store(in: defaults)
            XCTAssertEqual(DictationChunkSize.stored(in: defaults), size)
        }
    }

    /// A value from a build that offered a tier this one does not — or plain
    /// junk — must not turn live text off.
    func testUnknownStoredValueFallsBackToDefault() {
        defaults.set(999, forKey: DictationChunkSize.defaultsKey)
        XCTAssertEqual(DictationChunkSize.stored(in: defaults), .default)

        defaults.set("2240", forKey: DictationChunkSize.defaultsKey)
        XCTAssertEqual(DictationChunkSize.stored(in: defaults), .default)
    }

    /// The tiers are exactly what the library ships models for — a typo here
    /// means a download that 404s at the first dictation.
    func testTiersMatchTheShippedModels() {
        XCTAssertEqual(DictationChunkSize.allCases.map(\.milliseconds), [560, 1120, 2240, 4480])
    }

    func testEveryTierExplainsItsTradeOff() {
        for size in DictationChunkSize.allCases {
            XCTAssertFalse(size.title.isEmpty)
            XCTAssertFalse(size.explanation.isEmpty)
        }
    }
}
