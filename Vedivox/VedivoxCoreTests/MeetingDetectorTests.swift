import XCTest

final class MeetingDetectorTests: XCTestCase {
    private let active: Set<String> = ["com.google.Chrome", "us.zoom.xos"]
    private let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari"]
    private let telemostWeb = WebMeetingService.telemost.id

    func testMeetOffAsksNoBrowser() {
        let candidates = MeetingDetector.meetCandidateBrowsers(
            activeBundleIds: active, runningBrowsers: browsers, enabledApps: ["us.zoom.xos"]
        )
        XCTAssertEqual(candidates, [])
    }

    func testMeetOnAsksOnlyBrowsersPlayingAudio() {
        let candidates = MeetingDetector.meetCandidateBrowsers(
            activeBundleIds: active, runningBrowsers: browsers, enabledApps: [MeetingDetector.googleMeetId]
        )
        XCTAssertEqual(candidates, ["com.google.Chrome"])
    }

    func testTelemostOnAsksBrowsersToo() {
        let candidates = MeetingDetector.meetCandidateBrowsers(
            activeBundleIds: active, runningBrowsers: browsers, enabledApps: [telemostWeb]
        )
        XCTAssertEqual(candidates, ["com.google.Chrome"])
    }

    func testTelemostDesktopAppIsATarget() {
        XCTAssertEqual(ProcessMonitor.targetApps["ru.yandex.desktop.telemost"], "Yandex Telemost")
    }

    // MARK: - Tab URLs

    private func service(_ urls: [String], enabled: Set<String>? = nil) -> String? {
        let all = Set(WebMeetingService.all.map(\.id))
        return WebMeetingService.first(in: urls, enabledIds: enabled ?? all)?.id
    }

    func testMeetRooms() {
        for url in [
            "https://meet.google.com/abc-defg-hij",
            "https://meet.google.com/abc-defg-hij?authuser=1",
            "https://meet.google.com/abc-defg-hij/",
        ] {
            XCTAssertEqual(service([url]), MeetingDetector.googleMeetId, url)
        }
    }

    func testTelemostRooms() {
        for url in [
            "https://telemost.yandex.ru/j/12345678901234",
            "https://telemost.360.yandex.ru/j/1234567890?skip_app=1",
            "https://telemost.yandex.com/j/1234567890/",
            "https://telemost.yandex.ru/@/j/12345678901234",
            "https://telemost.360.yandex.ru/private-join/1234567890",
            "https://telemost.yandex.com.tr/j/1234567890",
        ] {
            XCTAssertEqual(service([url]), telemostWeb, url)
        }
    }

    func testLookalikesAreNotMeetings() {
        for url in [
            "https://meet.google.com/",
            "https://meet.google.com/landing",
            "https://www.google.com/url?q=https://meet.google.com/abc-defg-hij",
            "https://telemost.yandex.ru/",
            "https://telemost.360.yandex.ru/live/abcdef",
            "https://telemost.yandex.ru/j/",
            "https://telemost.yandex.ru/j/12345abc",
            "https://telemost.yandex.ru.evil.com/j/1234567890",
            "https://telemost.yandex.evil.com/j/1234567890",
            "https://telemost.360.yandex.attacker.org/j/1234567890",
            "https://telemost.yandex.ru.com/j/1234567890",
            "https://yandex.ru/search/?text=telemost.yandex.ru/j/1234567890",
            "https://notelemost.yandex.ru/j/1234567890",
            "missing value",
            "",
        ] {
            XCTAssertNil(service([url]), url)
        }
    }

    func testOnlyEnabledServicesMatch() {
        let tabs = ["https://example.com", "https://telemost.yandex.ru/j/1234567890", "https://meet.google.com/abc-defg-hij"]
        XCTAssertEqual(service(tabs, enabled: [MeetingDetector.googleMeetId]), MeetingDetector.googleMeetId)
        XCTAssertEqual(service(tabs, enabled: [telemostWeb]), telemostWeb)
        XCTAssertNil(service(tabs, enabled: ["us.zoom.xos"]))
    }

    // MARK: - Browsers that fail the tab script

    private let chrome = "com.google.Chrome"
    private let refused = BrowserTabDetector.ScriptError(
        code: -1743, message: "Not authorized to send Apple events to Google Chrome."
    )
    private let timedOut = BrowserTabDetector.ScriptError(code: -1712, message: "AppleEvent timed out.")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAFailedBrowserIsReportedAndTheNextOneStillAsked() {
        var detector = BrowserTabDetector()
        let refused = refused
        detector.readTabs = { name in
            name == "Google Chrome" ? .failure(refused) : .success(["https://meet.google.com/abc-defg-hij"])
        }
        let scan = detector.detect(runningBrowsers: browsers, enabledIds: [MeetingDetector.googleMeetId])
        XCTAssertEqual(scan.meeting?.browserName, "Safari")
        XCTAssertEqual(scan.asked.map { $0.name }, ["Google Chrome", "Safari"])
        XCTAssertEqual(scan.asked.map { $0.error }, [refused, nil])
    }

    /// The real NSAppleScript error dictionary, without an Apple Event: the script raises the error itself.
    func testAScriptErrorCarriesAppleScriptsCodeAndMessage() {
        XCTAssertEqual(
            BrowserTabDetector.run(#"error "Not authorized to send Apple events to Google Chrome." number -1743"#),
            .failure(refused)
        )
        XCTAssertEqual(BrowserTabDetector.run(#"return "a" & linefeed & "b" & linefeed"#), .success(["a", "b"]))
    }

    func testAScriptFailureIsLoggedOncePerChange() {
        var health = BrowserScriptHealth()
        func record(_ error: BrowserTabDetector.ScriptError?, after seconds: TimeInterval) -> String? {
            health.record(bundleId: chrome, name: "Google Chrome", error: error, now: t0 + seconds)
        }
        XCTAssertNil(record(nil, after: 0), "a browser that answers from the start is not news")
        let first = record(refused, after: 5)
        XCTAssertTrue(first?.contains("Google Chrome") == true && first?.contains("-1743") == true, first ?? "nil")
        XCTAssertNil(record(refused, after: 65), "the same refusal again")
        XCTAssertTrue(record(timedOut, after: 125)?.contains("-1712") == true, "another error is a change")
        XCTAssertNotNil(record(nil, after: 130), "so is answering again")
        XCTAssertNil(record(nil, after: 135))
    }

    func testARefusedBrowserIsAskedOnceAMinute() {
        var health = BrowserScriptHealth()
        XCTAssertTrue(health.shouldAsk(chrome, now: t0))
        _ = health.record(bundleId: chrome, name: "Google Chrome", error: refused, now: t0)
        XCTAssertFalse(health.shouldAsk(chrome, now: t0 + 5))
        XCTAssertFalse(health.shouldAsk(chrome, now: t0 + 59))
        XCTAssertTrue(health.shouldAsk(chrome, now: t0 + 60))
        XCTAssertTrue(health.shouldAsk("com.apple.Safari", now: t0 + 5), "the other browsers are not held back")

        // Any other error can be momentary (a window closing mid-script): skipping
        // polls after it would delay the start of a call by up to a minute.
        _ = health.record(bundleId: chrome, name: "Google Chrome", error: timedOut, now: t0 + 60)
        XCTAssertTrue(health.shouldAsk(chrome, now: t0 + 65))
    }
}
