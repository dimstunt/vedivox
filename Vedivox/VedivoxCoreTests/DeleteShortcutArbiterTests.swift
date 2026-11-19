import AppKit
import XCTest

/// Who gets Cmd+⌫.
///
/// The first attempt at this yielded the keystroke whenever *any* text field had
/// focus. The sidebar search field never gives focus up, so deleting a meeting
/// by keyboard became impossible — the fix was worse than the bug. The rule is
/// pinned here because it is pure logic and the failure was invisible to the
/// build.
final class DeleteShortcutArbiterTests: XCTestCase {

    private func canConsume(_ text: String, caret: Int, selecting length: Int = 0) -> Bool {
        DeleteShortcutArbiter.textEditorCanConsumeDeleteToLineStart(
            text: text,
            selection: NSRange(location: caret, length: length)
        )
    }

    /// The regression: an empty, permanently-focused search field must not
    /// swallow the shortcut.
    func testEmptyFieldYieldsShortcutToTheApp() {
        XCTAssertFalse(canConsume("", caret: 0))
    }

    /// The original incident: a half-typed title must keep the keystroke.
    func testCaretAfterTextConsumesShortcut() {
        XCTAssertTrue(canConsume("Alice / Robert 121", caret: 18))
        XCTAssertTrue(canConsume("Alice", caret: 1))
    }

    func testCaretAtLineStartYieldsShortcutToTheApp() {
        XCTAssertFalse(canConsume("Alice", caret: 0))
    }

    /// Entering rename mode selects the whole title: caret 0, selection non-empty.
    /// This is the case that kept raising the delete dialog while renaming.
    func testFullySelectedTitleConsumesShortcut() {
        XCTAssertTrue(canConsume("Alice / Robert 121", caret: 0, selecting: 18))
    }

    func testPartialSelectionAtLineStartConsumesShortcut() {
        XCTAssertTrue(canConsume("Alice", caret: 0, selecting: 2))
    }

    /// Multi-line: only the caret's own line counts, so sitting at the head of
    /// the second line leaves nothing to delete.
    func testCaretAtStartOfSecondLineYieldsShortcut() {
        XCTAssertFalse(canConsume("ab\ncd", caret: 3))
        XCTAssertTrue(canConsume("ab\ncd", caret: 4))
    }

    func testCaretPastEndIsTreatedAsNothingToDelete() {
        XCTAssertFalse(canConsume("ab", caret: 99))
    }

    /// UTF-16 offsets: NSText reports them, so a caret measured in code units
    /// past an emoji must not be mistaken for an out-of-range value.
    func testCaretIsInterpretedAsUTF16Offset() {
        XCTAssertTrue(canConsume("👋a", caret: 3))
    }

    // MARK: Was it the keystroke at all?

    private func keyDown(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
        ))
    }

    /// «Delete Meeting» picked in the ⌘K palette (Return) or clicked in the
    /// File menu used to wipe the text of the field focused behind it instead
    /// of asking about the meeting: only ⌘⌫ itself belongs to the field.
    func testOnlyCommandDeleteIsTheKeystroke() throws {
        XCTAssertTrue(DeleteShortcutArbiter.isDeleteKeystroke(try keyDown(51, .command)))
        XCTAssertFalse(DeleteShortcutArbiter.isDeleteKeystroke(try keyDown(36, [])), "Return в палитре ⌘K")
        XCTAssertFalse(DeleteShortcutArbiter.isDeleteKeystroke(try keyDown(51, [])), "⌫ без ⌘")
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ))
        XCTAssertFalse(DeleteShortcutArbiter.isDeleteKeystroke(click), "щелчок по File → Delete Meeting")
        XCTAssertFalse(DeleteShortcutArbiter.isDeleteKeystroke(nil), "команда без события")
    }
}
