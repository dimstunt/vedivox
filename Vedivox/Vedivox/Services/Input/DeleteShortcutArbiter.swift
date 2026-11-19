import AppKit

/// Who owns Cmd+⌫ — the focused text field, or the app's «delete meeting»?
///
/// macOS resolves menu key equivalents before the first responder sees the
/// event, so the app command always wins unless it steps aside deliberately
/// But «a text field has focus» is the wrong test to step aside on:
/// the sidebar search field holds focus permanently, which would make Cmd+⌫
/// unable to ever reach the meeting list.
///
/// The workable rule is narrower: yield the keystroke only when the editor can
/// actually act on it. An empty search field has nothing to delete, so the
/// shortcut belongs to the app; a half-typed title does, so it belongs to the
/// field.
enum DeleteShortcutArbiter {

    /// True when `event` is the ⌘⌫ keystroke itself. «Delete Meeting» also runs
    /// from a click on its menu item and from the ⌘K palette, with a text field
    /// still focused behind them: there it means the meeting, and nothing may
    /// be handed to the field.
    static func isDeleteKeystroke(_ event: NSEvent?) -> Bool {
        // keyCode traps on a non-key event, so the type goes first. 51 = kVK_Delete.
        guard let event, event.type == .keyDown else { return false }
        return event.keyCode == 51 && event.modifierFlags.contains(.command)
    }

    /// True when `deleteToBeginningOfLine:` would actually remove something.
    ///
    /// Pass `NSText.selectedRange` verbatim — offsets are UTF-16 code units.
    static func textEditorCanConsumeDeleteToLineStart(
        text: String,
        selection: NSRange
    ) -> Bool {
        // Entering rename mode selects the whole title, which puts the caret at
        // 0 with a non-empty selection. Looking only at the caret read that as
        // «nothing to delete» and handed Cmd+⌫ to the app — so renaming still
        // raised the delete dialog. A selection is itself something to delete.
        if selection.length > 0 { return true }

        let ns = text as NSString
        let caret = selection.location
        guard caret > 0, caret <= ns.length else { return false }

        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        return caret > lineStart
    }
}
