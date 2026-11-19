import AppKit

/// Which editable text, if any, currently owns the keyboard.
///
/// Used by the ⌘⌫ arbiter in `VedivoxApp` and by the detail anchor's click test.
/// The player keys no longer ask it: they act only while the window's
/// `DetailFocusAnchor` is first responder, which already excludes a focused
/// field and any other focused control.
@MainActor
enum TextFocus {

    /// The editor behind the first responder: SwiftUI text fields edit through
    /// the window's field editor (an `NSTextView`), `TextEditor` is one itself,
    /// and an `NSTextField` is only mid-edit while it has a current editor.
    static func editor(under responder: NSResponder?) -> NSTextView? {
        switch responder {
        case let textView as NSTextView where textView.isFieldEditor || textView.isEditable:
            return textView
        case let field as NSTextField:
            return field.currentEditor() as? NSTextView
        default:
            return nil
        }
    }
}
