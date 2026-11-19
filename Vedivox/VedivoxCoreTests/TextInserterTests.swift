import AppKit
import XCTest

/// The checks that decide whether ⌘V is worth sending at all, and the two waits
/// that surround it.
///
/// Everything here exists because a synthetic paste fails *silently*:
/// `CGEvent.post` returns void, so a refused event is indistinguishable from a
/// delivered one. The only defence is to not send the event when it is known in
/// advance that it cannot land.
@MainActor
final class TextInserterTests: XCTestCase {

    /// Counts how many times the sampler was asked, so a test can prove the wait
    /// actually polled instead of returning on the first look.
    private final class Samples {
        private(set) var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }

    // MARK: - Whether to ask for permission

    /// `CGRequestPostEventAccess` returns immediately while the system dialog
    /// appears asynchronously, so a dictation started alongside it records the
    /// user talking underneath an open permission prompt. The caller needs to
    /// know the prompt went up so it can skip this dictation entirely.
    func testPromptsOnTheFirstDictationWithoutPermission() {
        XCTAssertTrue(
            TextInserter.shouldPromptForAccess(canPostEvents: false, alreadyPrompted: false)
        )
    }

    func testDoesNotPromptWhenPermissionIsAlreadyGranted() {
        XCTAssertFalse(
            TextInserter.shouldPromptForAccess(canPostEvents: true, alreadyPrompted: false)
        )
    }

    /// macOS shows the prompt once per app and silently ignores later requests.
    /// Asking again would cost the user a dictation and show them nothing.
    func testDoesNotPromptASecondTime() {
        XCTAssertFalse(
            TextInserter.shouldPromptForAccess(canPostEvents: false, alreadyPrompted: true)
        )
    }

    // MARK: - Whether to paste at all

    func testReadyWhenPermissionIsGrantedAndAnotherAppIsFrontmost() {
        XCTAssertEqual(
            TextInserter.readiness(
                canPostEvents: true,
                hasFrontmostApp: true,
                frontmostIsSelf: false,
                secureInputEnabled: false
            ),
            .ready
        )
    }

    func testRefusesWithoutPermissionToPostEvents() {
        XCTAssertEqual(
            TextInserter.readiness(
                canPostEvents: false,
                hasFrontmostApp: true,
                frontmostIsSelf: false,
                secureInputEnabled: false
            ),
            .refused(.missingAccessibilityPermission)
        )
    }

    func testRefusesWhenNothingIsFrontmost() {
        XCTAssertEqual(
            TextInserter.readiness(
                canPostEvents: true,
                hasFrontmostApp: false,
                frontmostIsSelf: false,
                secureInputEnabled: false
            ),
            .refused(.noFrontmostApp)
        )
    }

    /// Settings opened during a dictation makes Vedivox itself the target, and the
    /// text disappears into our own window instead of the user's document.
    func testRefusesWhenVedivoxItselfIsFrontmost() {
        XCTAssertEqual(
            TextInserter.readiness(
                canPostEvents: true,
                hasFrontmostApp: true,
                frontmostIsSelf: true,
                secureInputEnabled: false
            ),
            .refused(.frontmostIsVedivox)
        )
    }

    /// Secure input is the case the whole check exists for: the system drops
    /// synthetic keystrokes entirely and reports nothing back.
    func testRefusesWhileSecureInputIsActive() {
        XCTAssertEqual(
            TextInserter.readiness(
                canPostEvents: true,
                hasFrontmostApp: true,
                frontmostIsSelf: false,
                secureInputEnabled: true
            ),
            .refused(.secureInput)
        )
    }

    /// Missing permission is the one failure the user can actually fix, so it is
    /// what they get told about when several things are wrong at once.
    func testMissingPermissionOutranksEveryOtherReason() {
        XCTAssertEqual(
            TextInserter.readiness(
                canPostEvents: false,
                hasFrontmostApp: false,
                frontmostIsSelf: true,
                secureInputEnabled: true
            ),
            .refused(.missingAccessibilityPermission)
        )
    }

    /// Secure input blocks delivery no matter which app is in front, so naming
    /// the frontmost app as the reason would send the user after the wrong thing.
    func testSecureInputOutranksTheFrontmostChecks() {
        XCTAssertEqual(
            TextInserter.readiness(
                canPostEvents: true,
                hasFrontmostApp: false,
                frontmostIsSelf: false,
                secureInputEnabled: true
            ),
            .refused(.secureInput)
        )
    }

    // MARK: - Clipboard confirmation

    /// The generation counter is the only evidence the write landed. Without it
    /// the fixed 60 ms wait could expire early and ⌘V would paste whatever the
    /// user had in the clipboard before — silently, into their document.
    func testClipboardIsNotConfirmedUntilTheGenerationAdvances() {
        XCTAssertFalse(
            TextInserter.pasteboardConfirmed(
                changeCount: 7,
                before: 7,
                contents: "распознанный текст",
                expected: "распознанный текст"
            )
        )
    }

    func testClipboardIsNotConfirmedWhileItHoldsSomethingElse() {
        XCTAssertFalse(
            TextInserter.pasteboardConfirmed(
                changeCount: 8,
                before: 7,
                contents: "чужой текст",
                expected: "распознанный текст"
            )
        )
    }

    func testClipboardIsNotConfirmedWhenItIsEmpty() {
        XCTAssertFalse(
            TextInserter.pasteboardConfirmed(
                changeCount: 8,
                before: 7,
                contents: nil,
                expected: "распознанный текст"
            )
        )
    }

    func testClipboardIsConfirmedOnceBothHold() {
        XCTAssertTrue(
            TextInserter.pasteboardConfirmed(
                changeCount: 8,
                before: 7,
                contents: "распознанный текст",
                expected: "распознанный текст"
            )
        )
    }

    /// A private pasteboard, never `.general`: the general one is the user's
    /// live clipboard, and a test suite has no business overwriting it.
    func testWritesTheTextAndConfirmsIt() async {
        let board = NSPasteboard(name: NSPasteboard.Name("com.dimstunt.Vedivox.tests.paste"))
        defer { board.releaseGlobally() }

        let confirmed = await TextInserter.writeAndConfirm("привет, дашборд", to: board)

        XCTAssertTrue(confirmed)
        XCTAssertEqual(board.string(forType: .string), "привет, дашборд")
    }

    // MARK: - Waiting for the hotkey modifiers

    func testDoesNotWaitWhenNoModifiersAreHeld() async {
        let clock = ContinuousClock()
        let start = clock.now

        let released = await TextInserter.waitForModifiersRelease(
            timeout: .seconds(5),
            poll: .milliseconds(5),
            sample: { [] }
        )

        XCTAssertTrue(released)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
    }

    /// ⇧⌘2 fires on key-up of the "2", while ⌘ and ⇧ are still physically down.
    /// Sending ⌘V into that lands as ⌘⇧V in the target app.
    func testWaitsUntilTheHotkeyModifiersAreReleased() async {
        let samples = Samples()

        let released = await TextInserter.waitForModifiersRelease(
            timeout: .seconds(5),
            poll: .milliseconds(5),
            sample: { samples.next() <= 3 ? [.maskCommand, .maskShift] : [] }
        )

        XCTAssertTrue(released)
        XCTAssertGreaterThan(samples.count, 3)
    }

    /// A user who keeps a modifier down forever must not block the dictation:
    /// the wait gives up and the caller pastes anyway.
    func testGivesUpWhenTheModifiersNeverClear() async {
        let released = await TextInserter.waitForModifiersRelease(
            timeout: .milliseconds(50),
            poll: .milliseconds(5),
            sample: { .maskCommand }
        )

        XCTAssertFalse(released)
    }

    /// Caps Lock cannot be part of a shortcut and is often on for minutes.
    func testIgnoresModifiersThatCannotBePartOfAShortcut() async {
        let released = await TextInserter.waitForModifiersRelease(
            timeout: .milliseconds(50),
            poll: .milliseconds(5),
            sample: { .maskAlphaShift }
        )

        XCTAssertTrue(released)
    }

    /// Task 2a.6: cancellation must not turn a wait into a hot loop or a hang.
    /// In pindrop the equivalent path let a `CancellationError` undo a paste
    /// that had already happened.
    func testStopsWaitingWhenTheSurroundingTaskIsCancelled() async {
        let clock = ContinuousClock()
        let start = clock.now

        let task = Task { @MainActor in
            await TextInserter.waitForModifiersRelease(
                timeout: .seconds(30),
                poll: .milliseconds(5),
                sample: { .maskCommand }
            )
        }
        task.cancel()
        _ = await task.value

        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
    }
}
