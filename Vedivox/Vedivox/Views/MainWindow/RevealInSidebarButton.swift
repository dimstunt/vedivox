import SwiftUI

/// Where the Reveal in Sidebar button sits: the owner is choosing by eye.
enum RevealButtonPlacement {
    /// Over the bottom-right corner of the meeting list, like Orca's «show current».
    case listCorner
    /// In the sidebar's search field, next to the filter.
    case searchField
    /// In the open meeting's header, next to the title.
    case meetingHeader

    /// The switch. A `var` only so the variant snapshots can render all three.
    @MainActor static var chosen: Self = .listCorner
}

/// Does what Edit → Reveal in Sidebar (⇧⌘J) does; the caller sets the look.
struct RevealInSidebarButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.view = .meetings
            appState.revealInSidebarRequest += 1
        } label: {
            Image(systemName: "scope")
        }
        .help(appState.shortcutText(.revealInSidebar).map { "Reveal in Sidebar (\($0))" } ?? "Reveal in Sidebar")
        .accessibilityLabel("Reveal in Sidebar")
        .accessibilityIdentifier("sidebar.reveal")
    }
}
