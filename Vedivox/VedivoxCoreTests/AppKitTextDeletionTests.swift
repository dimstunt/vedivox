import AppKit
import XCTest

/// Pins the AppKit semantics that `DeleteShortcutArbiter` is built on.
///
/// The arbiter yields ⌘⌫ to a focused editor whenever there is a non-empty
/// selection, on the premise that the system's «delete to beginning of line»
/// will actually remove it. That premise was assumed, then measured, and the
/// measurement is what proved the keystroke was being lost in delivery rather
/// than legitimately doing nothing.
///
/// Testing the framework is unusual, but this is an assumption the app depends
/// on and would otherwise break silently under a future macOS.
final class AppKitTextDeletionTests: XCTestCase {

    private func afterDeleteToLineStart(_ text: String, selection: NSRange) -> String {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.string = text
        textView.setSelectedRange(selection)
        textView.deleteToBeginningOfLine(nil)
        return textView.string
    }

    /// The premise the arbiter relies on: a double-click selection is removed,
    /// not ignored.
    func testSelectionStartingAtLineStartIsDeleted() {
        XCTAssertEqual(
            afterDeleteToLineStart("Alice / Robert 121", selection: NSRange(location: 0, length: 18)),
            ""
        )
        XCTAssertEqual(afterDeleteToLineStart("Zal", selection: NSRange(location: 0, length: 3)), "")
    }

    func testCaretAtEndClearsEverythingBefore() {
        XCTAssertEqual(afterDeleteToLineStart("Zal", selection: NSRange(location: 3, length: 0)), "")
    }

    /// The affected range is the union of «line start → selection start» and the
    /// selection itself, which is why a mid-line selection also takes the text
    /// in front of it.
    func testSelectionMidLineAlsoTakesTheTextBeforeIt() {
        XCTAssertEqual(afterDeleteToLineStart("Zal", selection: NSRange(location: 1, length: 2)), "Z")
    }

    /// The one case where the command genuinely does nothing — and the reason
    /// the arbiter must hand the keystroke back to the app here.
    func testCaretAtLineStartWithoutSelectionDeletesNothing() {
        XCTAssertEqual(afterDeleteToLineStart("Zal", selection: NSRange(location: 0, length: 0)), "Zal")
    }
}
