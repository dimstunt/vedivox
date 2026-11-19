import SwiftUI

/// Which half of the main window owns keyboard input (change
/// `fix-keyboard-and-focus`, group 2).
///
/// Before this the model was implicit and wrong: `TextField("Найти встречу")`
/// had no `@FocusState` at all, so it took focus as the first focusable view in
/// the window — and there was nowhere to hand it back to, because the detail
/// area contained nothing focusable. Every unmodified key therefore belonged to
/// the search field for the whole life of the window, and the player could not
/// be driven from the keyboard at all.
///
/// The detail region itself is not a case: `nil` means the keyboard belongs to
/// the region, held by `DetailFocusAnchor` (#1).
enum MainFocus: Hashable {
    case search
    /// The meeting title while it is being renamed. Setting it does not move
    /// focus into the field (see `TranscriptHeaderView.focusTitleField`); it
    /// keeps this state truthful once AppKit has focused the field, so leaving
    /// edit mode can hand the keyboard back to the region.
    case title
}

/// The detail region's keyboard holder: an AppKit view that takes first
/// responder whenever a detail screen appears.
///
/// SwiftUI focus could not do this (measured on a repro 2026-10-02): after the
/// detail column of a `NavigationSplitView` swaps its content, no `.focusable`
/// view in that column can be focused again — `focus = .detail` resigned the
/// search field and left first responder on the hosting view, so the player
/// keys went nowhere and the first Space after picking a meeting typed into
/// search. Real text fields are unaffected, and key presses still travel from
/// this view up through the SwiftUI ancestors that carry `.onKeyPress`.
struct DetailFocusAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {}

    /// Gives the keyboard back to the detail screen of the key window.
    @MainActor static func take() { AnchorView.of(NSApp.keyWindow)?.take() }

    /// The player keys act only while the window's anchor holds the keyboard:
    /// a focused text field, button or popup keeps its own keys (and
    /// Full Keyboard Access, where Space presses the focused control).
    @MainActor static func ownsKeys() -> Bool {
        NSApp.keyWindow?.firstResponder is AnchorView
    }

    /// A click on the region takes the keyboard back, unless the click landed
    /// in the text field that is editing (it is the click that focused it).
    /// Judged by the click point against the field's visible frame: a long
    /// description's text view is taller than its scroll view, so a test on
    /// the text view's own bounds misread it as outside. Returns whether it took.
    @MainActor static func takeUnlessClickInEditor() -> Bool {
        guard let window = NSApp.keyWindow, let anchor = AnchorView.of(window) else { return false }
        if let editor = TextFocus.editor(under: window.firstResponder),
           let click = NSApp.currentEvent, click.window === window {
            let field = (editor.isFieldEditor ? editor.delegate as? NSView : nil) ?? editor
            let visible = field.enclosingScrollView ?? field
            if visible.convert(visible.bounds, to: nil).contains(click.locationInWindow) { return false }
        }
        anchor.take()
        return true
    }

    final class AnchorView: NSView {
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            guard window != nil else { return }
            take()
        }

        /// The anchor of a window's current detail screen. Looked up per window
        /// rather than kept in a static, so a second main window (File → New
        /// Window) and a closed one cannot be confused.
        static func of(_ window: NSWindow?) -> AnchorView? {
            window?.contentView.flatMap(find)
        }

        private static func find(_ view: NSView) -> AnchorView? {
            if let anchor = view as? AnchorView { return anchor }
            for child in view.subviews.reversed() {
                if let anchor = find(child) { return anchor }
            }
            return nil
        }

        /// Async: the old screen's anchor leaves the window in the same pass
        /// and would hand first responder back to the window.
        func take() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if !window.makeFirstResponder(self) {
                    Log.debug("Detail anchor: first responder refused by \(String(describing: window.firstResponder))")
                }
            }
        }

        /// Reached only by keys no `.onKeyPress` handled — SwiftUI runs those
        /// before the first responder sees the event. A plain key means nothing
        /// here, so it is dropped instead of ringing the system bell
        /// (fix-keyboard-and-focus 3.4). Modified keys, Tab, Return and Esc
        /// travel on to the menu and the responder chain.
        override func keyDown(with event: NSEvent) {
            let passThrough: Set<UInt16> = [48, 36, 76, 53] // Tab, Return, Enter, Esc
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               !passThrough.contains(event.keyCode) {
                return
            }
            super.keyDown(with: event)
        }
    }
}

extension View {
    /// Marks this view as a detail screen that owns the keyboard when shown.
    ///
    /// Applied per branch rather than to a wrapper: `onKeyPress` reaches the
    /// first responder's SwiftUI ancestors, and the player keys need the
    /// transcript's own view model — which lives *below* any wrapper
    /// `ContentView` could add.
    func mainFocusTarget() -> some View {
        background(DetailFocusAnchor())
    }
}

extension FocusState<MainFocus?>.Binding {
    /// Hands the keyboard to the detail region.
    @MainActor func takeDetail() {
        wrappedValue = nil
        DetailFocusAnchor.take()
    }
}
