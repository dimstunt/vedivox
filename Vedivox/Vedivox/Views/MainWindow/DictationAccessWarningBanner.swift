import AppKit
import SwiftUI

/// Banner shown after a dictation could not be pasted because Vedivox lacks
/// Accessibility permission, so the user knows why the text only reached the
/// clipboard and where to fix it.
///
/// A passing notice is not enough here. macOS shows its own prompt only once per
/// app, and the grant does not take effect until Vedivox restarts — so the state can
/// outlive several dictations, and it needs a surface that stays put until it is
/// resolved. Modelled on `SystemAudioWarningBanner`, which solves the same
/// problem for screen-capture permission.
///
/// The restart is real, not caution: on 2026-11-16 one Vedivox process, after the
/// toggle went back on, read Zoom's mute and created the Escape tap
/// (`AXIsProcessTrusted` is live) yet was still refused `CGPreflightPostEventAccess`
/// on two dictations; the first dictation after a relaunch pasted.
/// So the banner cannot go away on its own — once the toggle is on, it says
/// that only a restart is left.
struct DictationAccessWarningBanner: View {
    @Environment(AppState.self) private var appState
    @State private var accessibilityGranted = AXIsProcessTrusted()

    var body: some View {
        if appState.dictationNeedsAccessibility {
            VedivoxBanner(
                .warning,
                title: "Dictation can\u{2019}t insert text",
                message: accessibilityGranted
                    ? "Accessibility is on, but macOS applies it to inserting text only after a restart. Quit and reopen Vedivox."
                    : "The text stays on the clipboard. Allow Vedivox in Accessibility and restart the app."
            ) {
                Image(systemName: "keyboard.badge.ellipsis")
            } trailing: {
                Button("Settings") {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.vedivoxGhost)
            }
            .padding(.horizontal, VedivoxSpace.l)
            .onAppear { Log.info("Banner appeared: dictation needs accessibility") }
            // The grant happens in System Settings; re-check when the user comes back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                accessibilityGranted = AXIsProcessTrusted()
                if accessibilityGranted { Log.info("Banner: accessibility granted, insertion waits for a restart") }
            }
        }
    }
}
