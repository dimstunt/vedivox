import AppKit
import SwiftUI

/// What a newer release brings, and the two ways to get it. Opened only from
/// a click (app menu, Help, Settings) — never on its own.
struct UpdateAvailableView: View {
    let release: UpdateChecker.Release
    @State private var copied = false

    private var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.l) {
            VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                Text("Vedivox \(release.version) is available")
                    .vedivoxFont(.title)
                    .foregroundStyle(Color.Vedivox.fg)
                Text("You have \(current).")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
            ScrollView {
                DescriptionMarkdownView(
                    source: release.notes.isEmpty ? "No release notes." : release.notes,
                    onSeek: { _ in }, onCheckboxToggle: { _ in }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: VedivoxSpace.s) {
                Button(copied ? "Copied" : "Copy Homebrew Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(VedivoxLinks.brewUpgradeCommand, forType: .string)
                    copied = true
                }
                .buttonStyle(.vedivoxGhost)
                .help(VedivoxLinks.brewUpgradeCommand)
                Spacer()
                Button("Open Release Page") { NSWorkspace.shared.open(release.page) }
                    .buttonStyle(.vedivoxProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(VedivoxSpace.xl)
        .background(Color.Vedivox.bg)
    }
}

@MainActor private var updateWindow: NSWindow?

/// One window, reused; a newer release found meanwhile replaces its content.
@MainActor
func showUpdateWindow(_ release: UpdateChecker.Release) {
    let window = updateWindow ?? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        window.center()
        updateWindow = window
        return window
    }()
    window.contentView = NSHostingView(rootView: UpdateAvailableView(release: release))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
