import AppKit
import Carbon.HIToolbox
import Foundation

/// Types the dictated text into whatever app currently has keyboard focus.
///
/// Route: put the text on the pasteboard, synthesize ⌘V into the target
/// process, and leave the text on the pasteboard. Every mature dictation app on
/// macOS converges on the paste route — direct Unicode `CGEvent` typing looks
/// cleaner but breaks on non-Cocoa apps and mangles text under non-US layouts.
///
/// **A synthetic paste fails silently.** `CGEvent.post` returns void: an event
/// the system refused looks exactly like one that landed in a text field. There
/// is no verification to add afterwards, so everything below is about not
/// sending the event when it is already known that it cannot work, and about
/// telling the user when that happens.
///
/// What the send waits on, and why each wait exists:
///
/// **The key that carries "v" is looked up, not assumed.** See `PasteKeyCode`:
/// the historical hard-coded 9 is a position on the keyboard, not a letter, and
/// on Dvorak that position is «.».
///
/// **Command is pressed for real, not just flagged.** Hypervisors (VMware,
/// Parallels, VirtualBox) pass a bare "v" to the guest when they see
/// `.maskCommand` without a physical Command key-down alongside it.
///
/// **The clipboard is confirmed before ⌘V goes out.** Sending the shortcut on a
/// timer means that if the write has not landed yet, the target app pastes
/// whatever the user had in the clipboard before — into their document, with no
/// error anywhere.
///
/// **The hotkey's own modifiers have to be released first.** ⇧⌘2 fires while ⌘
/// and ⇧ are still physically down, and ⌘V sent into that arrives as ⌘⇧V.
///
/// **Delivery goes to the target PID.** `postToPid` is a minority choice — six
/// of the eight dictation apps surveyed post to `.cghidEventTap` — and it is
/// kept for one narrow reason: it addresses the app that was frontmost when the
/// decision was made, so a focus change during the send cannot redirect the
/// text. It is *not* what makes terminals and Electron apps behave: no surveyed
/// project supports that, terminal trouble shows up regardless of delivery
/// method, and FluidVoice, the only other `postToPid` user, routes Ghostty away
/// from this path onto the clipboard instead.
///
/// **The text stays on the clipboard.** Earlier this restored the previous
/// contents ~400 ms after pasting. The user asked for the opposite: a dictation
/// should always also be in the clipboard, so it survives a paste that lands in
/// the wrong window or an app that quietly refuses it. The cost is deliberate —
/// the previous clipboard entry is replaced.
@MainActor
enum TextInserter {

    enum Outcome: Equatable {
        /// Text was pasted into the target application, named here so the
        /// history can record where it went — the target is only settled at
        /// paste time, so nothing earlier knows it.
        case inserted(app: String?)
        /// No paste was performed. The text is on the clipboard unless the
        /// reason says otherwise, and the caller should tell the user.
        case copiedToClipboard(reason: FailureReason)
    }

    /// Why the paste did not happen. Typed rather than a string because the
    /// cases are not interchangeable: the missing-permission one is the only one
    /// the user can fix and persists until they do, and one of them means the
    /// text is not on the clipboard either.
    enum FailureReason: Equatable {
        case missingAccessibilityPermission
        case noFrontmostApp
        /// Vedivox itself was frontmost — Settings opened during a dictation, say.
        /// Pasting would put the text into our own window.
        case frontmostIsVedivox
        /// The system is filtering synthetic keystrokes (focus in a password
        /// field, or an app that left secure input on).
        case secureInput
        case clipboardWriteFailed

        var message: String {
            switch self {
            case .missingAccessibilityPermission: "No Accessibility permission"
            case .noFrontmostApp: "No frontmost app"
            case .frontmostIsVedivox: "Vedivox window is frontmost"
            case .secureInput: "Secure input is on"
            case .clipboardWriteFailed: "Could not write to the clipboard"
            }
        }

        /// Whether the "press ⌘V yourself" advice is true for this failure.
        var textIsOnClipboard: Bool {
            self != .clipboardWriteFailed
        }
    }

    /// Whether ⌘V is worth sending at all.
    enum Readiness: Equatable {
        case ready
        case refused(FailureReason)
    }

    /// Gap between synthesized key events. Non-Cocoa apps (Minecraft/LWJGL,
    /// Raycast) drop the modifier and receive a bare "v" if this is too tight.
    private static let keyEventGap: Duration = .milliseconds(20)
    /// How often the pasteboard and the modifier keys are re-read while waiting.
    /// `nonisolated` because it is a default argument, and those are evaluated
    /// outside the actor.
    private nonisolated static let pollInterval: Duration = .milliseconds(5)
    /// Cap on waiting for the pasteboard to report our text. Normally satisfied
    /// on the first look — this is the "something is badly wrong" bound.
    private static let clipboardTimeout: Duration = .milliseconds(150)
    /// Cap on waiting for the hotkey modifiers. Long enough for a human to let
    /// go of ⇧⌘, short enough that someone resting on Command still gets their
    /// dictation.
    private nonisolated static let modifierTimeout: Duration = .milliseconds(600)
    /// The modifiers a shortcut can be built from. Caps Lock is excluded on
    /// purpose: it cannot be part of one and is often on for minutes.
    private static let shortcutModifiers: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate,
    ]

    /// Whether synthetic events may be posted at all.
    ///
    /// `CGPreflightPostEventAccess` maps to `kTCCServicePostEvent`, which System
    /// Settings displays inside the Accessibility pane — the same toggle users
    /// know, under a different service name internally.
    static var canPostEvents: Bool {
        CGPreflightPostEventAccess()
    }

    /// Asks for permission, showing the system prompt once.
    @discardableResult
    static func requestEventAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    /// Whether the system prompt has to go up before this dictation.
    ///
    /// macOS shows it once per app and silently ignores every later request, so
    /// asking again would cost the user a dictation and show them nothing. After
    /// that the route is System Settings, which is what
    /// `DictationAccessWarningBanner` is for.
    nonisolated static func shouldPromptForAccess(
        canPostEvents: Bool,
        alreadyPrompted: Bool
    ) -> Bool {
        !canPostEvents && !alreadyPrompted
    }

    /// Shows the system Accessibility prompt the first time dictation is used
    /// without permission, and reports whether it did.
    ///
    /// The return value is not advisory: `CGRequestPostEventAccess` comes back
    /// immediately while the dialog appears asynchronously, so a caller that
    /// starts recording anyway records the user talking underneath an open
    /// permission dialog. Whoever prompts must skip this dictation.
    ///
    /// Until this existed nothing ever called `requestEventAccess`, so the prompt
    /// never appeared and there was no in-app path to grant access at all —
    /// dictation silently fell back to the clipboard forever.
    @discardableResult
    static func requestEventAccessIfNeeded() -> Bool {
        let flag = "dictationAccessibilityPromptShown"
        guard shouldPromptForAccess(
            canPostEvents: canPostEvents,
            alreadyPrompted: UserDefaults.standard.bool(forKey: flag)
        ) else { return false }
        UserDefaults.standard.set(true, forKey: flag)

        let granted = requestEventAccess()
        Log.info("Dictation: asked for PostEvent access, granted=\(granted)")
        return true
    }

    // MARK: - Insertion

    static func insert(_ text: String) async -> Outcome {
        guard !text.isEmpty else { return .inserted(app: nil) }

        guard await writeAndConfirm(text, to: .general) else {
            Log.error("Dictation: the clipboard never reported the text — not sending ⌘V")
            return .copiedToClipboard(reason: .clipboardWriteFailed)
        }

        // Before reading the frontmost app, not after: letting go of ⇧⌘ takes a
        // human a few tens of milliseconds, and the target is whoever is in
        // front once the shortcut is fully over.
        if await !waitForModifiersRelease() {
            Log.info("Dictation: hotkey modifiers still held after \(modifierTimeout), pasting anyway")
        }

        let target = NSWorkspace.shared.frontmostApplication
        let verdict = readiness(
            canPostEvents: canPostEvents,
            hasFrontmostApp: target != nil,
            frontmostIsSelf: target?.processIdentifier == NSRunningApplication.current.processIdentifier,
            secureInputEnabled: IsSecureEventInputEnabled()
        )

        if case .refused(let reason) = verdict {
            Log.info("Dictation: not pasting — \(reason.message); text left on clipboard")
            return .copiedToClipboard(reason: reason)
        }
        guard let pid = target?.processIdentifier else {
            // Unreachable: `.ready` already means there is a frontmost app.
            return .copiedToClipboard(reason: .noFrontmostApp)
        }

        sendPasteShortcut(key: PasteKeyCode.resolve(), to: pid)
        return .inserted(app: target?.localizedName)
    }

    /// Everything that has to hold before a paste can land, in the order the
    /// user should hear about it.
    ///
    /// Permission comes first because it is the only failure they can act on.
    /// Secure input comes next because it blocks delivery no matter which app is
    /// in front — naming the frontmost app there would send them after the
    /// wrong thing.
    nonisolated static func readiness(
        canPostEvents: Bool,
        hasFrontmostApp: Bool,
        frontmostIsSelf: Bool,
        secureInputEnabled: Bool
    ) -> Readiness {
        if !canPostEvents { return .refused(.missingAccessibilityPermission) }
        if secureInputEnabled { return .refused(.secureInput) }
        if !hasFrontmostApp { return .refused(.noFrontmostApp) }
        if frontmostIsSelf { return .refused(.frontmostIsVedivox) }
        return .ready
    }

    // MARK: - Clipboard

    /// Writes the text and waits until the pasteboard says it holds it.
    ///
    /// No transient/auto-generated markers: those tell clipboard managers not to
    /// keep the entry, which is the opposite of what is wanted now — the text is
    /// meant to stay reachable after the paste.
    static func writeAndConfirm(_ text: String, to pasteboard: NSPasteboard) async -> Bool {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let deadline = ContinuousClock.now.advanced(by: clipboardTimeout)
        while true {
            if pasteboardConfirmed(
                changeCount: pasteboard.changeCount,
                before: before,
                contents: pasteboard.string(forType: .string),
                expected: text
            ) { return true }

            guard ContinuousClock.now < deadline, await sleepQuietly(for: pollInterval) else {
                return false
            }
        }
    }

    /// The generation counter alone is not proof: it advances on
    /// `clearContents()` too, so a write that failed afterwards would still look
    /// like a new generation. Both have to hold.
    nonisolated static func pasteboardConfirmed(
        changeCount: Int,
        before: Int,
        contents: String?,
        expected: String
    ) -> Bool {
        changeCount != before && contents == expected
    }

    // MARK: - Waiting for the hotkey to be over

    /// Waits until none of the shortcut modifiers are physically held.
    ///
    /// Returns whether they cleared: a timeout is not a reason to abandon the
    /// dictation, only something to log.
    static func waitForModifiersRelease(
        timeout: Duration = modifierTimeout,
        poll: Duration = pollInterval,
        sample: () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if sample().isDisjoint(with: shortcutModifiers) { return true }
            guard ContinuousClock.now < deadline, await sleepQuietly(for: poll) else {
                return false
            }
        }
    }

    /// Sleeps, reporting whether the sleep completed.
    ///
    /// A cancelled task must leave the loops above immediately rather than spin
    /// through `try?` until the deadline — and cancellation must not be able to
    /// undo a paste that has already happened, which is exactly how the
    /// equivalent path went wrong in pindrop.
    private static func sleepQuietly(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }

    // MARK: - The keystroke itself

    /// Synthesizes ⌘V into a specific process.
    ///
    /// Command is pressed and released as a real key around V, not merely set as
    /// a flag: hypervisors hand the guest a bare "v" otherwise.
    ///
    /// The gaps are `usleep`, not `await`: this is a 60 ms critical section in
    /// which Command is held down synthetically. Suspending inside it would let
    /// another main-actor task run — a second hotkey press, a cancel — between
    /// the down and the up, and leave Command stuck down system-wide.
    private static func sendPasteShortcut(key: CGKeyCode, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let command = CGKeyCode(kVK_Command)

        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false)
        else { return }

        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // Command is gone by the time this one is delivered.
        commandUp.flags = []

        let gap = UInt32(keyEventGap.components.attoseconds / 1_000_000_000_000)
        for event in [commandDown, keyDown, keyUp] {
            event.postToPid(pid)
            usleep(gap)
        }
        commandUp.postToPid(pid)
    }
}
