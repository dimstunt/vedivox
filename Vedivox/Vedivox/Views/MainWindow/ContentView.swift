import KeyboardShortcuts
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    /// Owned here because both halves of the window need it: the sidebar's
    /// search field and whatever screen the detail area is showing.
    @FocusState private var focus: MainFocus?
    /// The palette row picked, run once its sheet is gone.
    @State private var palettePick: PaletteItem?

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView(focus: $focus)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 320)
        } detail: {
            detail
                // Fill the column so the inset band pins to the top, not to
                // the centered empty state.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Own band under the toolbar, detail column only:
                // an .overlay on the split view floated the banners over the
                // toolbar, traffic lights and the sidebar's search field, and a
                // split-view-level inset is ignored by the sidebar column.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: VedivoxSpace.m) {
                        ModelLoadingBanner()
                        SystemAudioWarningBanner()
                        DictationAccessWarningBanner()
                        StarBanner()
                    }
                }
                // Here, not on the screen that registered the undo: by ⌘Z that
                // screen is often another one, and its alert state went with it.
                .alert("Could Not Undo", isPresented: Binding(
                    get: { appState.speakerUndoFailure != nil }, set: { if !$0 { appState.speakerUndoFailure = nil } }
                )) {
                    Button("OK") {}
                } message: {
                    Text(appState.speakerUndoFailure ?? "")
                }
        }
        .onChange(of: appState.focusSearchRequest) { _, _ in
            focus = .search
        }
        .sheet(isPresented: $appState.commandPaletteOpen, onDismiss: {
            palettePick?.perform()
            palettePick = nil
        }) {
            CommandPaletteView(
                onPick: { item in
                    palettePick = item
                    appState.commandPaletteOpen = false
                },
                onCancel: { appState.commandPaletteOpen = false }
            )
        }
        // Widest sidebar (320) + transcript column (560, TranscriptView) +
        // inspector (320): below that the meeting screen overflowed, clipping
        // the inspector and spilling over the sidebar.
        .frame(minWidth: 1210, minHeight: 500)
        .overlay {
            if appState.showOnboarding {
                OnboardingView()
            }
        }
        // The one and only delete confirmation. Both the sidebar
        // context menu and the main-menu command route through
        // AppState.requestDeleteMeetings, so this cannot be bypassed by a view
        // that forgets to ask — which is exactly how it went missing before.
        .alert(
            appState.pendingDeletePrompt,
            isPresented: Binding(
                get: { !appState.pendingDeleteIds.isEmpty },
                set: { if !$0 { appState.cancelPendingDelete() } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                appState.cancelPendingDelete()
            }
            Button("Delete", role: .destructive) {
                appState.confirmPendingDelete()
            }
        } message: {
            Text("The audio goes to the Trash; the transcript is deleted from the database.")
        }
        .vedivoxToolbarBackgroundHidden()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: VedivoxSpace.xxs) {
                    Button { appState.navigateBack() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!appState.canGoBack)
                    .keyboardShortcut(appState.shortcut(.navigateBack))
                    .help("Back")
                    .accessibilityIdentifier("toolbar.back")
                    .accessibilityLabel("Back")

                    Button { appState.navigateForward() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!appState.canGoForward)
                    .keyboardShortcut(appState.shortcut(.navigateForward))
                    .help("Forward")
                    .accessibilityIdentifier("toolbar.forward")
                    .accessibilityLabel("Forward")
                }
            }
        }
        .onChange(of: appState.selectedMeetingIds) { _, newValue in
            if newValue.count == 1, let id = newValue.first {
                appState.view = .meetings
                appState.pushNavigation(.meeting(id))
            }
        }
        .onAppear {
            appState.openMainWindow = { openWindow(id: "main") }
        }
        .onChange(of: appState.view) { _, newValue in
            switch newValue {
            // The meeting already selected is shown again: still a step back
            // from Settings or Speakers (#2). A new selection pushes
            // the same entry from its own onChange; the duplicate is skipped.
            case .meetings:
                if let id = appState.selectedMeetingId { appState.pushNavigation(.meeting(id)) }
            case .speakers: appState.pushNavigation(.speakers)
            case .listen: appState.pushNavigation(.listen)
            case .series: appState.pushNavigation(.series)
            case .dictations: appState.pushNavigation(.dictations)
            case .settings: appState.pushNavigation(.settings)
            }
        }
        .task {
            await appState.loadMeetings()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if appState.libraryUpdate != nil {
            // No section is mounted while the database is copied and
            // migrated: each would open onto the same wait (Speakers sat 36 s
            // on its first query) with an empty list to show for it.
            ContentUnavailableView(
                "Updating Your Library",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("Your meetings will be back as soon as it is done. Nothing is lost — a copy is made first.")
            )
            .mainFocusTarget()
        } else {
            sections
        }
    }

    @ViewBuilder
    private var sections: some View {
        switch appState.view {
        case .speakers:
            SpeakerManagementView().mainFocusTarget()
        case .listen:
            // Applies the focus target itself, like the transcript: its keys
            // need `onKeyPress` on the focused view.
            ListenView()
        case .series:
            SeriesManagementView().mainFocusTarget()
        case .settings:
            SettingsView().mainFocusTarget()
        case .dictations:
            DictationsView().mainFocusTarget()
        case .meetings:
            if let meetingId = appState.selectedMeetingId {
                // Applies the focus target itself: its player keys read the
                // transcript's view model, and `onKeyPress` must live on the
                // focused view rather than under it.
                TranscriptView(meetingId: meetingId, focus: $focus)
            } else if appState.selectedMeetingIds.count > 1 {
                ContentUnavailableView(
                    "\(appState.selectedMeetingIds.count) Meetings Selected",
                    systemImage: "checkmark.circle",
                    description: Text("Right-click for batch actions.")
                )
                .mainFocusTarget()
            } else if appState.meetings.isEmpty {
                Self.noMeetingsYet(
                    record: KeyboardShortcuts.getShortcut(for: .toggleRecording),
                    importing: KeyboardShortcuts.getShortcut(for: .importRecording)
                )
                .mainFocusTarget()
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "waveform",
                    description: Text("Select a meeting from the sidebar or start a new recording.")
                )
                .mainFocusTarget()
            }
        }
    }

    /// The first window a new user sees: the three ways a meeting gets in.
    /// The keys are the user's current shortcuts, nil when cleared.
    static func noMeetingsYet(
        record: KeyboardShortcuts.Shortcut?, importing: KeyboardShortcuts.Shortcut?
    ) -> some View {
        let recordLine = record.map { "Press \($0) to record a meeting" } ?? "Start a recording from the menu bar"
        let importLine = importing.map { "\($0) to import a recording" } ?? "File → Import Recording to bring one in"
        return ContentUnavailableView(
            "No Meetings Yet",
            systemImage: "waveform",
            description: Text("\(recordLine), \(importLine), or drag an audio or video file onto this window.")
        )
    }
}
