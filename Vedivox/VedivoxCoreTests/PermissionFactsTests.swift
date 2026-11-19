import CoreServices
import XCTest

/// Settings → Privacy & Permissions rows for System audio and Automation.
final class PermissionFactsTests: XCTestCase {
    func testAppleEventCodes() {
        XCTAssertEqual(PermissionFacts.Answer(0), .allowed)
        XCTAssertEqual(PermissionFacts.Answer(-1743), .refused)
        XCTAssertEqual(PermissionFacts.Answer(-1744), .notAsked)
        XCTAssertEqual(PermissionFacts.Answer(-600), .notRunning)
        XCTAssertEqual(PermissionFacts.Answer(-50), .unknown(-50))
    }

    func testAutomationRow() {
        let mixed = PermissionFacts.automation([
            ("Chrome", .allowed), ("Arc", .allowed), ("Safari", .notAsked), ("Edge", .notRunning),
        ])
        XCTAssertEqual(mixed.grant, .notAsked, "not asked is not a refusal")
        XCTAssertTrue(mixed.caption.hasPrefix("Allowed for Chrome, Arc · Safari not asked yet. "), mixed.caption)

        let allRunning = PermissionFacts.automation([("Chrome", .allowed), ("Safari", .notRunning)])
        XCTAssertEqual(allRunning.grant, .allowed)

        let refused = PermissionFacts.automation([("Chrome", .allowed), ("Safari", .refused)])
        XCTAssertEqual(refused.grant, .refused)
        XCTAssertTrue(refused.caption.hasPrefix("Allowed for Chrome · not allowed for Safari. "), refused.caption)

        let noneRunning = PermissionFacts.automation([("Chrome", .notRunning)])
        XCTAssertEqual(noneRunning.grant, .unknown)
        XCTAssertTrue(noneRunning.caption.hasPrefix("Unknown: no supported browser is running"), noneRunning.caption)
    }

    /// The proof is this install's own: a sounding system track in a recording
    /// it has just made, kept in its settings for 30 days.
    func testSystemAudioRowFromTheLastHeardRecording() throws {
        let suite = "PermissionFactsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()

        let never = PermissionFacts.systemAudio(defaults, now: now)
        XCTAssertEqual(never.grant, .unknown)
        XCTAssertTrue(never.caption.hasPrefix("Not confirmed yet."), never.caption)

        PermissionFacts.noteSystemAudioHeard(defaults, at: now.addingTimeInterval(-3 * 86400))
        let heard = PermissionFacts.systemAudio(defaults, now: now)
        XCTAssertEqual(heard.grant, .allowed)
        XCTAssertTrue(heard.caption.hasPrefix("Allowed. Vedivox heard system audio on "), heard.caption)

        PermissionFacts.noteSystemAudioHeard(defaults, at: now.addingTimeInterval(-40 * 86400))
        XCTAssertEqual(PermissionFacts.systemAudio(defaults, now: now).grant, .unknown, "too old to prove anything")
    }

    /// A check that heard nothing says why it cannot tell, and keeps the
    /// Check button; an older proof still wins over it.
    func testSystemAudioRowAfterACheck() {
        let silent = PermissionFacts.systemAudio(lastCapture: nil, check: .silent)
        XCTAssertEqual(silent.grant, .unknown)
        XCTAssertTrue(silent.caption.hasPrefix("Not confirmed yet. Nothing was playing"), silent.caption)
        XCTAssertTrue(silent.caption.contains("Screen & System Audio Recording"), silent.caption)

        let failed = PermissionFacts.systemAudio(lastCapture: nil, check: .failed(-50))
        XCTAssertTrue(failed.caption.contains("error -50"), failed.caption)

        XCTAssertNil(PermissionFacts.systemAudioHint(.heard))
        XCTAssertEqual(PermissionFacts.systemAudio(lastCapture: Date(), check: .silent).grant, .allowed)
        XCTAssertEqual(PermissionFacts.action(silent.grant, canAsk: false, canCheck: true), .check)
        XCTAssertEqual(PermissionFacts.action(.allowed, canAsk: false, canCheck: true), .openSettings)
        XCTAssertEqual(PermissionFacts.action(.unknown, canAsk: true), .openSettings, "notifications before their read")
    }

    /// The wizard names the browsers macOS will ask later, while they are closed.
    func testAutomationAskedInTheWizard() {
        XCTAssertEqual(
            PermissionFacts.automationAsked([("Arc", .allowed), ("Safari", .notRunning), ("Edge", .notRunning)]),
            "Allowed for Arc. Safari, Edge: not open, so macOS asks the first time Vedivox looks at their tabs."
        )
        XCTAssertEqual(PermissionFacts.automationAsked([("Arc", .refused)]), "Not allowed for Arc.")
        XCTAssertEqual(
            PermissionFacts.automationAsked([("Safari", .notRunning)]),
            "No supported browser is open. Safari: not open, so macOS asks the first time Vedivox looks at its tabs."
        )
    }

    /// The old app's proof never reaches the new identifier's settings.
    func testSystemAudioProofIsNotCarriedOver() {
        let legacy: [String: Any] = [PermissionFacts.systemAudioHeardKey: Date(), "defaultLanguage": "en"]
        let carried = LegacySettings.carriedOver(from: legacy, into: [:])
        XCTAssertNil(carried[PermissionFacts.systemAudioHeardKey])
        XCTAssertEqual(carried["defaultLanguage"] as? String, "en")
    }

    /// Every row has a mark; not asked and unknown share the neutral one.
    func testMarkByGrant() {
        XCTAssertEqual(PermissionFacts.mark(.allowed), .allowed)
        XCTAssertEqual(PermissionFacts.mark(.refused), .refused)
        XCTAssertEqual(PermissionFacts.mark(.notAsked), .neutral)
        XCTAssertEqual(PermissionFacts.mark(.unknown), .neutral)
        XCTAssertEqual(PermissionFacts.Mark.neutral.symbol, "questionmark.circle")
    }

    /// Allow (macOS's own prompt) only before the first answer and only where
    /// macOS can prompt; Open Settings everywhere else.
    func testActionByGrant() {
        XCTAssertEqual(PermissionFacts.action(.notAsked, canAsk: true), .ask)
        XCTAssertEqual(PermissionFacts.action(.notAsked, canAsk: false), .openSettings)
        for grant in [PermissionFacts.Grant.allowed, .refused, .unknown] {
            XCTAssertEqual(PermissionFacts.action(grant, canAsk: true), .openSettings, "\(grant)")
        }
    }

    /// The caption starts with the status word.
    func testCaptionStartsWithTheStatus() {
        XCTAssertEqual(PermissionFacts.Row(.allowed, purpose: "For X.").caption, "Allowed. For X.")
        XCTAssertEqual(PermissionFacts.Row(.refused, purpose: "For X.").caption, "Not allowed. For X.")
        XCTAssertEqual(PermissionFacts.Row(.notAsked, purpose: "For X.").caption, "Not asked yet. For X.")
    }

    /// Calendars checked in Settings → Meetings without access are said out loud.
    func testCalendarsCheckedWithoutAccess() {
        XCTAssertEqual(PermissionFacts.calendarStatus(.allowed, checked: 2), "Allowed.")
        XCTAssertEqual(PermissionFacts.calendarStatus(.notAsked, checked: 0), "Not asked yet.")
        XCTAssertEqual(
            PermissionFacts.calendarStatus(.notAsked, checked: 1),
            "Not asked yet. 1 calendar is checked for meeting titles, but Vedivox cannot read it."
        )
        XCTAssertEqual(
            PermissionFacts.calendarStatus(.refused, checked: 3),
            "Not allowed. 3 calendars are checked for meeting titles, but Vedivox cannot read them."
        )
        XCTAssertEqual(PermissionFacts.mark(PermissionFacts.calendars(.notAsked, checked: 1).grant), .neutral)
        XCTAssertEqual(PermissionFacts.Grant(CalendarService.AuthStatus.notDetermined), .notAsked)
    }
}
