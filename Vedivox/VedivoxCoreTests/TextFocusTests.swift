import AppKit
import XCTest

/// Who gets Space and the arrows — the player or the text under the caret
@MainActor
final class TextFocusTests: XCTestCase {

    func testNoResponderLeavesKeysToThePlayer() {
        XCTAssertNil(TextFocus.editor(under: nil))
        XCTAssertNil(TextFocus.editor(under: NSView()))
    }

    /// The title field: SwiftUI edits through the window's field editor.
    func testFieldEditorOwnsKeys() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        XCTAssertNotNil(TextFocus.editor(under: editor))
    }

    /// `TextEditor` (the description in the inspector) is an editable text view.
    func testEditableTextViewOwnsKeys() {
        let textView = NSTextView()
        textView.isEditable = true
        XCTAssertNotNil(TextFocus.editor(under: textView))
    }

    /// Read-only selectable text has no caret to move: the player keeps the keys.
    func testReadOnlyTextViewLeavesKeysToThePlayer() {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        XCTAssertNil(TextFocus.editor(under: textView))
    }

    /// A text field that is not being edited (no current editor) does not own them.
    func testIdleTextFieldLeavesKeysToThePlayer() {
        XCTAssertNil(TextFocus.editor(under: NSTextField()))
    }
}
