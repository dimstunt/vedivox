import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct VedivoxApp: App {
    @State private var appState: AppState
    @State private var isImporting = false
    @NSApplicationDelegateAdaptor(VedivoxAppDelegate.self) private var appDelegate

    @AppStorage("voxTheme") private var vedivoxTheme: VedivoxTheme = .dark
    /// The `.id` below rebuilds the window on a palette switch so every token
    /// resolves the new palette.
    @AppStorage(VedivoxPalette.defaultsKey) private var vedivoxPalette: VedivoxPalette = .mono

    /// Claims the data directory before anything else exists.
    ///
    /// The order is the point, not a detail: `AppState()` registers the
    /// dictation hotkey and subscribes to database change notifications, and
    /// the first database access migrates the file. On 2026-08-14 a stray
    /// second copy did exactly that — it grabbed the hotkey and picked up an
    /// orphaned meeting to process alongside the running app. Everything the
    /// losing instance must not do happens after this switch, so declining here
    /// is what prevents it.
    init() {
        // First of all, and before the first log line: the claim below and the
        // log both create the data directory, and the library of someone who
        // used the app under its old name can only move into a free place.
        let arrival = Self.adoptLegacyLibrary()

        switch DataDirectoryLock.acquire(in: DataDirectory.root) {
        case .acquired:
            arrival.forEach { $0() }
            _appState = State(initialValue: AppState())
        case .busy(let holder):
            Self.yieldToRunningInstance(holder)
        case .unavailable(let reason):
            Self.reportUnusableDataDirectory(reason)
        }
    }

    /// Brings over what the app left under its old name: the library, the
    /// names of the files in it, the settings. Nothing here may log — see
    /// `DataDirectoryMigration` — so what happened comes back as the log lines
    /// to write once the directory is claimed.
    @MainActor
    private static func adoptLegacyLibrary() -> [() -> Void] {
        var notes: [() -> Void] = []
        let root = DataDirectory.root

        // Only the real library: a test host and a launch pointed at another
        // directory have no business moving the user's data.
        if root == DataDirectory.production {
            let legacy = DataDirectoryMigration.legacyProduction
            switch DataDirectoryMigration.move(from: legacy, to: root) {
            case .nothingToMove:
                break
            case .moved:
                notes.append { Log.info("VedivoxApp: the library moved from \(legacy.path) to \(root.path)") }
            case .bothExist:
                notes.append {
                    Log.warning(
                        "VedivoxApp: a library exists at both \(legacy.path) and \(root.path) — "
                            + "using \(root.path); nothing was merged and the other one is untouched"
                    )
                }
            case .inUse:
                reportLegacyAppRunning()
            case .failed(let reason):
                reportLibraryNotMoved(reason, from: legacy, to: root)
            }
        }

        guard !DataDirectory.isTestProcess(environment: ProcessInfo.processInfo.environment) else { return notes }

        switch DataDirectoryMigration.renameFiles(in: root) {
        case .moved:
            notes.append { Log.info("VedivoxApp: the database and the logs in \(root.path) got their new names") }
        case .failed(let reason):
            reportUnusableDataDirectory(reason)
        case .nothingToMove, .bothExist, .inUse:
            // In use: another instance is running there, and the claim says so next.
            break
        }

        if let carried = LegacySettings.adopt(), carried > 0 {
            notes.append { Log.info("VedivoxApp: \(carried) settings came over from \(LegacyNames.bundleIdentifier)") }
        }
        return notes
    }

    /// The app under its old name is running and holds the library. A library
    /// is not moved from under a running app, so this says what to do and goes.
    @MainActor
    private static func reportLegacyAppRunning() -> Never {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit \(LegacyNames.appName) first"
        alert.informativeText = """
            \(LegacyNames.appName) is called Vedivox now, and Vedivox takes over its library the first \
            time it opens. \(LegacyNames.appName) is still running and holds that library: quit it when \
            nothing is recording, then open Vedivox again. Nothing has been changed.
            """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(0)
    }

    /// The library could not be moved to the new name. It is whole and where it
    /// was; the way out is to move it by hand.
    @MainActor
    private static func reportLibraryNotMoved(_ reason: String, from legacy: URL, to root: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Vedivox could not take over your library"
        alert.informativeText = """
            Your meetings are still in \(legacy.path), and nothing there has been changed.

            \(reason)

            Quit Vedivox, move that folder to \(root.path) yourself (in Finder, or with mv in \
            Terminal), and open Vedivox again.
            """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }

    /// Leaves the data directory to its owner and exits, quietly.
    ///
    /// Quietly is the point: this code is unreachable from the way a person
    /// opens an app. Dock, Finder and Spotlight do not start a second process
    /// for a bundle that is already running — LaunchServices matches the
    /// identifier and activates the running copy itself. What reaches here is a
    /// direct exec, a script, a background `open -g`, or another build aimed at
    /// the same directory: launches where nobody asked for a window.
    ///
    /// An earlier version raised the holder's window from here, and it stole
    /// focus during the very check meant to prove this path works. The project
    /// already knew better — `ImportFileTool` passes `-g -j` so an import never
    /// unhides the app — and this path had simply not been held to that rule.
    private static func yieldToRunningInstance(_ holder: DataDirectoryHolder?) -> Never {
        Log.info(
            "VedivoxApp: \(DataDirectory.root.path) is already in use"
                + (holder.map { " by pid \($0.pid) (\($0.bundlePath))" } ?? "")
                + " — yielding without touching the data or the focus"
        )

        exit(0)
    }

    /// Nobody holds the data directory — it cannot be used at all (not
    /// writable, the disk is full). Unlike `yieldToRunningInstance` this is
    /// reachable by simply opening the app, so it must say something: it used
    /// to share that quiet exit, and Vedivox just did not open.
    @MainActor
    private static func reportUnusableDataDirectory(_ reason: String) -> Never {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Vedivox cannot use its data folder"
        alert.informativeText = reason
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }

    /// Tells the user why Vedivox cannot run, then quits.
    ///
    /// Quitting is the point: the refusal exists to keep the data untouched,
    /// and a half-running app over a database it must not read is not a safer
    /// state than no app.
    @MainActor
    private static func reportUnusableDatabase(_ reason: String) -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Vedivox cannot open its database"
        alert.informativeText = reason
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .id(vedivoxPalette)
                .environment(appState)
                // The theme reaches the window only through NSApp.appearance
                // (applyToApp below), never .preferredColorScheme: after Light,
                // .preferredColorScheme(nil) left the window light instead of
                // following macOS for System.
                .tint(Color.Vedivox.accent)
                .vedivoxWindowBackground(vedivoxPalette)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onChange(of: vedivoxTheme, initial: true) { _, theme in
                    theme.applyToApp()
                }
                .onChange(of: vedivoxPalette) {
                    appState.menuBarController.paletteDidChange()
                }
                .onAppear {
                    // Once per process. `onAppear` fires again whenever the
                    // window is recreated — reopened from the menu bar, or a
                    // palette switch through `.id` — and a second pass took the
                    // recording in progress for a crashed one: it "recovered"
                    // the live WAV, compressed it and deleted it under the
                    // recorder. It also stacked a second global-hotkey handler.
                    guard appState.claimLaunchTasks() else { return }
                    appDelegate.appState = appState
                    Task {
                        // Menu bar first: it touches only UserDefaults and
                        // NSStatusBar and must not wait behind the DB loads
                        // below — the icon is the recording indicator and
                        // must be up the moment the app is.
                        appState.setupMenuBar()

                        // Nothing below this line may run on a database the
                        // app must not touch.
                        if let reason = await appState.preflightDatabase() {
                            Self.reportUnusableDatabase(reason)
                        }

                        // Before the loads: a command that arrives during a
                        // cold start is the normal case, not a race — the
                        // command is often what launched the app. Nothing in
                        // the handlers depends on the sidebar being populated.
                        appState.startCommandServer()

                        // One anonymous GET a day at most; off in Settings → About.
                        appState.updateChecker.start()

                        await appState.loadMeetings()
                        await appState.loadSeries()
                        // Named now, recovered last — see the end of this task.
                        let orphans = appState.orphanedRecordings()

                        // Wire notification actions
                        appState.notificationService.onStartRecordingRequested = { [weak appState] in
                            Task { await appState?.startRecordingFromBackground() }
                        }
                        appState.notificationService.onMeetingEndedIndicator = { [weak appState] indicator in
                            appState?.menuBarController.setMeetingEnded(indicator)
                        }

                        // Wire menu bar actions
                        appState.menuBarController.onStartRecording = { [weak appState] in
                            Task { await appState?.startRecordingFromBackground() }
                        }
                        appState.menuBarController.onStartMultiSpeakerRecording = { [weak appState] in
                            Task { await appState?.startRecordingFromBackground(foreignVoiceDecision: .kept) }
                        }
                        appState.menuBarController.onKeepRecording = { [weak appState] in
                            appState?.notificationService.keepRecording()
                        }
                        appState.menuBarController.onStopRecording = { [weak appState] in
                            guard let appState else { return }
                            Task { await appState.recordingVM.stopRecording(appState: appState) }
                        }

                        // Meeting detection is opt-in and deferred until the
                        // welcome wizard finishes — otherwise a
                        // fresh install fires browser Apple Events / notification
                        // prompts before the user records anything. Model warm-up
                        // runs regardless so models are ready either way.
                        if !appState.showOnboarding {
                            await appState.enableNotifications()
                            await appState.startDetection()
                        }

                        // Pre-load transcription model in background
                        await appState.warmUpModel()

                        // And the live-draft model, which takes ~17.5 s to load
                        // even from disk — at the first hotkey press that delay
                        // eats the whole dictation.
                        appState.dictationController.prewarmLiveDraft()

                        // Before recovery: a cut-short dictation is seconds, recovery minutes.
                        await appState.recoverInterruptedDictations()

                        // Last: recovery runs the whole pipeline over each
                        // meeting a crash interrupted — minutes. It used to
                        // run before the wiring above, and all that time
                        // Start/Stop in the menu bar and in notifications
                        // called nothing and no meeting was detected.
                        await appState.recoverOrphanedRecordings(orphans)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                    return true
                }
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: FileImporter.supportedTypes,
                    allowsMultipleSelection: false
                ) { result in
                    handleFileImport(result)
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .textEditing) {
                // Toggles: the same key closes the palette.
                Button(CommandPaletteView.menuTitle) {
                    if !appState.commandPaletteOpen { appState.showMainWindow() }
                    appState.commandPaletteOpen.toggle()
                }
                .keyboardShortcut(appState.shortcut(.commandPalette))

                // Disabled off the meetings screen on purpose, and that is the
                // whole conflict resolution: Speakers and Series declare their
                // own ⌘F for their own search fields as in-view shortcuts, and
                // a menu equivalent would beat them every time. A *disabled*
                // menu item does not consume the key, so it falls through to
                // whichever screen is showing.
                Button("Find Meeting") {
                    appState.focusSearchRequest += 1
                }
                .keyboardShortcut(appState.shortcut(.findInView))
                .disabled(appState.view != .meetings)

                // Scrolls the sidebar to the open meeting, clearing a search
                // or speaker filter that hides it.
                Button("Reveal in Sidebar") {
                    appState.view = .meetings
                    appState.revealInSidebarRequest += 1
                }
                .keyboardShortcut(appState.shortcut(.revealInSidebar))
                .disabled(appState.selectedMeetingId == nil)
            }

            // Replacing (not after) .newItem drops File → New Window: a second
            // main window on the shared state only mirrors the first. An empty
            // replacement would remove the whole File menu.
            CommandGroup(replacing: .newItem) {
                Button("Import Recording...") {
                    isImporting = true
                }
                .keyboardShortcut(appState.shortcut(.importRecording))

                Divider()

                // Registered equivalents of the sidebar context-menu items
                // a shortcut shown in a menu must actually work.
                Button("Export to Markdown") {
                    if let id = appState.selectedMeetingId {
                        Task { await appState.exportMeeting(id) }
                    }
                }
                .keyboardShortcut(appState.shortcut(.exportMarkdown))
                .disabled(appState.selectedMeetingId == nil)

                Button("Delete Meeting") {
                    // Cmd+⌫ is also the system «delete to beginning of line»,
                    // and NSMenu resolves key equivalents BEFORE the first
                    // responder sees the event — so while a text field is
                    // focused this action fires instead of editing the text.
                    // Hand the keystroke back to the field (this is
                    // how a 3h recording died to a rename typo).
                    if forwardDeleteToFocusedTextField() { return }

                    let ids = appState.selectedMeetingIds.isEmpty
                        ? appState.selectedMeetingId.map { Set([$0]) } ?? []
                        : appState.selectedMeetingIds
                    guard !ids.isEmpty else { return }
                    appState.requestDeleteMeetings(ids)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(appState.selectedMeetingId == nil && appState.selectedMeetingIds.isEmpty)
            }

            // Settings live in the main window only; the separate Settings
            // scene was a second copy of them.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { appState.showMainWindow(settings: true) }
                    .keyboardShortcut(",", modifiers: .command)
            }

            // The stock About panel plus where the code lives.
            CommandGroup(replacing: .appInfo) {
                Button("About Vedivox") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Star Vedivox on GitHub",
                            attributes: [.link: VedivoxLinks.repository]
                        ),
                    ])
                    NSApp.activate(ignoringOtherApps: true)
                }
                updateMenuItem
            }

            // Replaces the stock "Vedivox Help", which has no Help Book to show.
            CommandGroup(replacing: .help) {
                Button("Vedivox Guide") { openBundledDocument("GUIDE", as: "Vedivox Guide") }
                Button("What\u{2019}s New") { openBundledDocument("CHANGELOG", as: "Vedivox Changelog") }
                Divider()
                Button("Star Vedivox on GitHub") { NSWorkspace.shared.open(VedivoxLinks.repository) }
                updateMenuItem
            }
        }

    }

    /// Present only while a newer release is known: no item, no noise.
    @ViewBuilder
    private var updateMenuItem: some View {
        if let release = appState.updateChecker.available {
            Button("Vedivox \(release.version) Is Available\u{2026}") { showUpdateWindow(release) }
        }
    }

    // MARK: - Cmd+⌫ Disambiguation

    /// When the focused text field has something to delete on the caret's line,
    /// deliver Cmd+⌫ there as the system «delete to beginning of line» and
    /// report that the keystroke was consumed.
    ///
    /// Returns false when no editor can act on it — including the very common
    /// case of the always-focused, empty sidebar search field — leaving the
    /// caller free to treat the shortcut as «delete meeting». Also false when
    /// the command did not come from ⌘⌫ at all: picked in the ⌘K palette or
    /// clicked in the File menu it means the meeting, whatever field has focus.
    private func forwardDeleteToFocusedTextField() -> Bool {
        guard DeleteShortcutArbiter.isDeleteKeystroke(NSApp.currentEvent),
              let editor = TextFocus.editor(under: NSApp.keyWindow?.firstResponder), DeleteShortcutArbiter.textEditorCanConsumeDeleteToLineStart(
                  text: editor.string,
                  selection: editor.selectedRange
              ) else { return false }

        // Call the editor directly instead of routing through
        // NSApp.sendAction. The send never arrived: AppKit deletes exactly this
        // kind of selection (pinned by AppKitTextDeletionTests), yet in the app
        // nothing happened and no delete dialog appeared — so the keystroke was
        // consumed here and then lost. A direct call removes the responder-chain
        // guesswork.
        editor.deleteToBeginningOfLine(nil)
        return true
    }

    // MARK: - Drop Support

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                Task {
                    _ = try? await FileImporter.importFile(
                        url: url,
                        appState: appState,
                        pipeline: appState.pipeline
                    )
                }
            }
        }
    }

    // MARK: - URL Scheme

    private func handleOpenURL(_ url: URL) {
        // Navigation only. A link can come from a web page or a pasted note,
        // so nothing that changes data is reachable through the scheme; import
        // and reprocess travel the command socket, which answers for them.
        guard let link = VedivoxLinks.meetingLink(url) else { return }
        appState.pendingSeekTime = link.seekTime
        appState.selectedMeetingId = link.meetingId
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                _ = try? await FileImporter.importFile(
                    url: url,
                    appState: appState,
                    pipeline: appState.pipeline
                )
            }
        case .failure(let error):
            Log.error("File import failed: \(error)")
        }
    }
}

/// One window per bundled document, reused when the menu item is chosen again.
@MainActor private var documentWindows: [String: NSWindow] = [:]

/// Shows a bundled markdown file (GUIDE, CHANGELOG) rendered in a Vedivox window.
/// Opening the raw .md in the default app showed markup — in Zed, Xcode or
/// TextEdit, whichever the user happens to have.
@MainActor
private func openBundledDocument(_ name: String, as title: String) {
    if let window = documentWindows[name] {
        window.makeKeyAndOrderFront(nil)
        return
    }
    guard let url = Bundle.main.url(forResource: name, withExtension: "md"),
          let source = try? String(contentsOf: url, encoding: .utf8) else {
        Log.error("Bundled \(name).md is missing or unreadable")
        return
    }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ScrollView {
        // About 70 characters of body text a line, centred on a wide window.
        DescriptionMarkdownView(source: source, onSeek: { _ in }, onCheckboxToggle: { _ in }, sectionGap: VedivoxSpace.xl)
            .lineSpacing(VedivoxSpace.xxs)
            .frame(maxWidth: 480)
            .padding(VedivoxSpace.xxxl)
            .frame(maxWidth: .infinity)
    }
    .background(Color.Vedivox.bg))
    window.center()
    documentWindows[name] = window
    window.makeKeyAndOrderFront(nil)
}

/// ⌘Q, a logout or a restart with a meeting in progress. Without
/// it a quit was a crash: both tracks left open and no end time.
@MainActor
final class VedivoxAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the launch tasks; until then there is nothing to stop.
    weak var appState: AppState?
    private var poweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ContextMenuTrace.install()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poweringOff = true }
        }
    }

    /// A quit, logout or restart is not a recovery that died: the next launch runs it again.
    func applicationWillTerminate(_ notification: Notification) {
        RecoveryMarker().end()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        let decision = QuitGuard.decide(
            recording: appState.recordingVM.isRecording,
            // A stopped recording keeps its in-progress status until the pipeline is done.
            processing: appState.meetings.contains { $0.status.isInProgress },
            dictating: appState.dictationController.state != .idle,
            poweringOff: poweringOff
        )
        Log.info("Quit requested: \(decision)")
        let dictation = appState.dictationController
        // The dictation first: saving it is a file move, stopping a recording takes seconds.
        let stop: @MainActor () async -> Void = {
            await dictation.saveForLater()
            if appState.recordingVM.isRecording { await appState.recordingVM.stopRecording(appState: appState) }
        }
        switch decision {
        case .quitNow:
            return .terminateNow
        case .stopFirst:
            QuitGuard.stopThenQuit(stop: stop, reply: { sender.reply(toApplicationShouldTerminate: $0) })
            return .terminateLater
        case .askAboutProcessing:
            let alert = NSAlert()
            alert.messageText = "Vedivox is still processing a meeting"
            alert.informativeText = "If you quit now, processing starts over the next time Vedivox opens."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit")
            // Quit from the menu bar leaves another app in front, the alert behind it.
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        case .askAboutDictation:
            let alert = NSAlert()
            alert.messageText = "Vedivox is still dictating"
            alert.informativeText = "If you quit now, nothing is inserted. The recording is saved to Dictations and transcribed the next time Vedivox opens."
                + (appState.recordingVM.isRecording ? " The meeting recording stops and is saved too." : "")
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            QuitGuard.stopThenQuit(
                stop: {
                    await stop()
                    // Music the dictation paused resumes from a Task that would die with the process.
                    await dictation.backgroundAudio.endAndWait()
                },
                reply: { sender.reply(toApplicationShouldTerminate: $0) }
            )
            return .terminateLater
        }
    }
}
