import XCTest

final class SemanticVersionTests: XCTestCase {
    private func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    func testNumericNotLexicalOrder() {
        XCTAssertLessThan(v("0.9.9"), v("0.10.0"))
        XCTAssertLessThan(v("0.4.2"), v("0.4.10"))
        XCTAssertLessThan(v("1.9.0"), v("10.0.0"))
    }

    func testTagPrefixAndBuildMetadata() {
        XCTAssertEqual(v("v1.2.3"), v("1.2.3"))
        XCTAssertEqual(v("1.2.3+build.7"), v("1.2.3"))
    }

    func testPrereleasesRankBelowTheRelease() {
        XCTAssertLessThan(v("1.0.0-beta.2"), v("1.0.0"))
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-alpha.1"))
        XCTAssertLessThan(v("1.0.0-beta.2"), v("1.0.0-beta.11"))
        XCTAssertLessThan(v("1.0.0-1"), v("1.0.0-alpha"))
        XCTAssertLessThan(v("0.9.9"), v("1.0.0-rc.1"))
    }

    func testGarbageIsRejected() {
        for tag in ["", "latest", "1.2", "1.2.3.4", "1..3", "v", "1.2.x", "1.2.3-", "1.2.3-a..b", "-1.2.3", "１.2.3"] {
            XCTAssertNil(SemanticVersion(tag), tag)
        }
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private actor Calls {
        var count = 0
        func hit() { count += 1 }
    }

    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "UpdateCheckerTests-\(UUID().uuidString)")
    }

    private func checker(current: String = "0.4.2", tag: String = "v0.5.0", status: Int = 200, calls: Calls)
        -> UpdateChecker {
        UpdateChecker(currentVersion: current, defaults: defaults, now: { [unowned self] in clock }, fetch: { request in
            await calls.hit()
            let body = #"{"tag_name":"\#(tag)","html_url":"https://github.com/o/r/releases/tag/\#(tag)","body":"- fix"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }

    func testNewerReleaseIsOffered() async {
        let calls = Calls()
        let sut = checker(calls: calls)
        await sut.checkIfDue()
        XCTAssertEqual(sut.available?.version, "0.5.0")
        XCTAssertEqual(sut.available?.notes, "- fix")
    }

    func testSameOrOlderIsNotOffered() async {
        for tag in ["0.4.2", "v0.4.1", "0.5.0-beta.1-garbage..", "nightly"] {
            let sut = checker(current: "0.4.2", tag: tag, calls: Calls())
            await sut.check()
            XCTAssertNil(sut.available, tag)
        }
    }

    func testAtMostOncePerDay() async {
        let calls = Calls()
        let sut = checker(calls: calls)
        await sut.checkIfDue()
        clock += 23 * 3600
        await sut.checkIfDue()
        var count = await calls.count
        XCTAssertEqual(count, 1)
        clock += 3600
        await sut.checkIfDue()
        count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testFailureAlsoWaitsADay() async {
        let calls = Calls()
        let sut = checker(status: 404, calls: calls)
        await sut.checkIfDue()
        await sut.checkIfDue()
        let count = await calls.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(sut.status, .failed)
        XCTAssertNil(sut.available)
    }

    func testSwitchedOffMakesNoRequest() async {
        defaults.set(false, forKey: UpdateChecker.enabledKey)
        let calls = Calls()
        await checker(calls: calls).checkIfDue()
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testFoundReleaseSurvivesRelaunchUntilInstalled() async {
        await checker(calls: Calls()).check()
        XCTAssertEqual(checker(calls: Calls()).available?.version, "0.5.0")
        XCTAssertNil(checker(current: "0.5.0", calls: Calls()).available)
    }
}
