import AppKit
import KeyboardShortcuts
import SnapshotTesting
import SwiftUI
import XCTest

/// The main screens rendered offscreen in every palette × theme:
/// the check that contrast holds in the app as drawn, not only in token values.
///
/// Nothing here may reach the person using the Mac while it runs. The bundle
/// has no host app, so there is no Vedivox process, window, Dock icon or
/// activation; views render in a borderless window that is never ordered in.
/// Defaults are the xctest tool's, never Vedivox's, but shared by every xctest
/// process on the Mac: palette and theme go into this process's argument
/// domain (`setForThisProcess`). Data lives in a throwaway directory
/// (`make test-snapshots` sets VEDIVOX_DATA_DIR) — checked before anything is
/// created.
///
/// Re-record after a visual change: `make test-snapshots RECORD=1`, then look
/// at the PNGs in `__Snapshots__` (or `scripts/snapshot_sheet.py`) before
/// committing them.
@MainActor
final class ScreenSnapshotTests: XCTestCase {

    private static var appState: AppState?
    static var rendered: [NSView] = []
    static let meetingId = "AAAAAAAA-0000-0000-0000-00000000000A"

    override func invokeTest() {
        let record = ProcessInfo.processInfo.environment["VEDIVOX_SNAPSHOT_RECORD"] == "1"
        withSnapshotTesting(record: record ? .all : .missing) { super.invokeTest() }
    }

    /// The window ground follows the palette handed to it, not the one stored
    /// when SwiftUI first resolved it: a switch on the fly must change both the
    /// light and the dark shade.
    func testWindowGroundIsPinnedToThePaletteGiven() {
        func rgb(_ color: Color, _ name: NSAppearance.Name) -> [CGFloat] {
            var components: [CGFloat] = []
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                components = NSColor(color).usingColorSpace(.sRGB)!.cgColor.components!
            }
            return components
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            Self.setForThisProcess([VedivoxPalette.defaultsKey: VedivoxPalette.ink.rawValue])
            let site = rgb(Color.Vedivox.bg, name)
            Self.setForThisProcess([VedivoxPalette.defaultsKey: VedivoxPalette.mono.rawValue])
            let mono = rgb(Color.Vedivox.bg, name)
            XCTAssertNotEqual(site, mono)
            XCTAssertEqual(rgb(Color.Vedivox.bg(.ink), name), site, "\(name.rawValue): ink ground while mono is stored")
            XCTAssertEqual(rgb(Color.Vedivox.bg(.mono), name), mono)
        }
    }

    /// `---` in the Guide is a line, not a list item "--" or text.
    func testMarkdownRule() {
        let blocks = parseMarkdown("Above\n\n---\n\n***\n- item\n", hooks: .init(scheme: .light))
        XCTAssertEqual(blocks.map { "\($0)".prefix(4) }, ["para", "rule", "rule", "list"])
    }

    func testSidebarIdle() async throws {
        let state = try await Self.state()
        state.recordingVM.state = .idle
        try await snapshotAllThemes("sidebar-idle", size: CGSize(width: 300, height: 640)) {
            SidebarHarness()
        }
    }

    func testSidebarRecording() async throws {
        let state = try await Self.state()
        state.recordingVM.state = .recording
        defer { state.recordingVM.state = .idle }
        try await snapshotAllThemes("sidebar-recording", size: CGSize(width: 300, height: 640)) {
            SidebarHarness()
        }
    }

    /// The meeting under the pointer right below the open one:
    /// hover and active fills side by side, which the full sidebar never shows.
    func testSidebarRowStates() async throws {
        _ = try await Self.state()
        try await snapshotAllThemes("sidebar-row-states", size: CGSize(width: 300, height: 280)) {
            SidebarRowsHarness()
        }
    }

    /// The run-grouped transcript with a search hit and the segment under the
    /// playhead, plus the player bar and the inspector.
    func testTranscript() async throws {
        try await snapshotTranscript("transcript", editMode: false)
    }

    /// The per-segment edit list, the only place ⌘-selection exists.
    func testTranscriptEdit() async throws {
        try await snapshotTranscript("transcript-edit", editMode: true)
    }

    /// The track filter on Mic: only the mic lines and «Exclude mic track».
    func testTranscriptMicTrack() async throws {
        try await snapshotTranscript("transcript-mic-track", editMode: false, track: .mic)
    }

    private func snapshotTranscript(
        _ name: String, editMode: Bool, track: AudioTrack = .mix, testName: String = #function
    ) async throws {
        _ = try await Self.state()
        try await snapshotAllThemes(name, size: CGSize(width: 1180, height: 720), testName: testName) {
            let viewModel = MeetingDetailViewModel()
            return (TranscriptHarness(viewModel: viewModel, editMode: editMode), { () async in
                viewModel.trackFilter = track
                guard track == .mix else { return }
                // "Thursday" hits three lines, so the ⌘-selected one (Nora's)
                // and the one under the playhead (the second) both stay visible.
                viewModel.searchText = "Thursday"
                let ids = viewModel.segments.compactMap(\.id)
                if editMode, ids.count > 4 { viewModel.selectedSegmentIds = [ids[4]] }
                viewModel.playback.currentTime = viewModel.segments.dropFirst().first?.startTime ?? 0
            })
        }
    }

    /// The window of a meeting being recorded (live-transcript 8.2): live text
    /// with a recognised speaker, a voice without a name, the owner and speech
    /// nobody was told apart in — and the same window before anybody speaks.
    func testLiveTranscript() async throws {
        _ = try await Self.state()
        func turn(_ start: Double, _ speaker: LiveSpeaker, _ text: String, mic: Bool = false) -> LiveTranscriptLog.Turn {
            .init(track: mic ? .mic : .system, speaker: speaker, start: start, end: start + 6, text: text)
        }
        let spoken = LiveTranscriptScreenModel()
        spoken.show([
            turn(61, LiveSpeaker(kind: .known, name: "Clara Meyer", confidence: 0.84),
                 "Can we still ship on Thursday if the review slips a day?"),
            turn(69, LiveSpeaker(kind: .unknown, name: "Speaker 2"),
                 "Depends on the migration. It has to finish first, and nobody has looked at the row counts since Monday."),
            turn(78, .me, "The migration is done, I compared the counts this morning.", mic: true),
            turn(84, .others, "Okay."),
        ])
        try await snapshotAllThemes("live-transcript", size: CGSize(width: 760, height: 320)) {
            LiveTranscriptContent(model: spoken)
        }
        let silent = LiveTranscriptScreenModel()
        silent.show([])
        try await snapshotAllThemes("live-transcript-listening", size: CGSize(width: 760, height: 320)) {
            LiveTranscriptContent(model: silent)
        }
    }

    /// The Split sheet opened while listening: the cut sits at the start of
    /// the segment under the playhead, with the step buttons.
    func testSplitSheet() async throws {
        _ = try await Self.state()
        try await snapshotAllThemes("split-sheet", size: CGSize(width: 560, height: 430)) {
            SplitHarness()
        }
    }

    /// The Trim sheet: both bounds with the step buttons of the chosen one.
    func testTrimSheet() async throws {
        _ = try await Self.state()
        try await snapshotAllThemes("trim-sheet", size: CGSize(width: 560, height: 430)) {
            SplitHarness(mode: .trim)
        }
    }

    /// The main window before the first meeting: how to record, import or drop a file.
    func testNoMeetingsYet() async throws {
        _ = try await Self.state()
        try await snapshotAllThemes("no-meetings-yet", size: CGSize(width: 760, height: 420)) {
            // The defaults, passed in: storing them would register global hot keys in this process.
            ContentView.noMeetingsYet(
                record: KeyboardShortcuts.Name.toggleRecording.defaultShortcut,
                importing: KeyboardShortcuts.Name.importRecording.defaultShortcut
            )
        }
    }

    func testSeries() async throws {
        _ = try await Self.state()
        try await snapshotAllThemes("series", size: CGSize(width: 1000, height: 600)) { SeriesManagementView() }
    }

    func testSpeakers() async throws {
        _ = try await Self.state()
        try await snapshotAllThemes("speakers", size: CGSize(width: 1000, height: 600)) { SpeakerManagementView() }
    }

    /// The ⌘K palette: a name found as a speaker, a series and a
    /// meeting title; then commands with their keys next to screens.
    func testCommandPalette() async throws {
        _ = try await Self.state()
        func command(_ title: String, _ key: String) -> PaletteItem {
            PaletteItem(id: "command:\(title)", kind: .command, title: title, shortcut: key, icon: "command") {}
        }
        let commands = [
            command("Start Recording", "⇧⌘1"), command("Export to Markdown", "⇧⌘E"), command("Reveal in Sidebar", "⇧⌘J"),
        ]
        for (name, query) in [("command-palette", "nora"), ("command-palette-commands", "re")] {
            try await snapshotAllThemes(name, size: CGSize(width: 600, height: 420)) {
                CommandPaletteView(menuCommands: commands, initialQuery: query, onPick: { _ in }, onCancel: {})
            }
        }
    }

    // Every Settings section at the defaults, tall enough to show it whole
    // (the settings review). Storage is left out: it prints the data
    // directory, a fresh random path on every run.
    func testSettingsGeneral() async throws { try await snapshotSettings(.general, height: 480) }
    func testSettingsRecording() async throws { try await snapshotSettings(.recording, height: 760) }
    func testSettingsMeetings() async throws { try await snapshotSettings(.meetings, height: 480) }
    /// With detection on: its rows and the calendars show (hidden while off).
    func testSettingsMeetingsDetecting() async throws {
        Self.setForThisProcess([MeetingAutomation.detectionEnabledKey: true])
        defer { Self.setForThisProcess([MeetingAutomation.detectionEnabledKey: false]) }
        try await snapshotSettings(.meetings, height: 600)
    }

    func testSettingsTranscript() async throws { try await snapshotSettings(.transcript, height: 720) }
    func testSettingsDictation() async throws { try await snapshotSettings(.dictation, height: 480) }
    func testSettingsMyVoice() async throws { try await snapshotSettings(.myVoice, height: 480) }
    func testSettingsShortcuts() async throws { try await snapshotSettings(.shortcuts, height: 1700) }
    func testSettingsPrivacy() async throws { try await snapshotSettings(.privacy, height: 620) }
    func testSettingsAbout() async throws { try await snapshotSettings(.about, height: 640) }
    /// A full-screen window: the column stands in the middle of the pane.
    func testSettingsGeneralWide() async throws {
        try await snapshotSettings(.general, width: 1600, height: 480, name: "settings-general-wide")
    }

    private func snapshotSettings(_ section: SettingsView.Section, width: CGFloat = 1000, height: CGFloat,
                                  name: String? = nil, testName: String = #function) async throws {
        let state = try await Self.state()
        state.settingsSection = section
        try await snapshotAllThemes(name ?? "settings-\(section.rawValue)", size: CGSize(width: width, height: height),
                                    testName: testName) { SettingsView() }
    }

    /// Microphone priority list on made-up devices: the head is
    /// unplugged, so the second is current; a virtual driver sits last.
    func testMicPriorityList() async throws {
        _ = try await Self.state()
        let list = MicPriority(devices: [
            .init(uid: "studio", name: "Studio USB Mic"),
            .init(uid: "laptop", name: "Laptop Microphone"),
            MicPriority.systemDefault,
            .init(uid: "buds", name: "Wireless Buds"),
            .init(uid: "meeting", name: "Meeting App Audio", isVirtual: true),
        ])
        try await snapshotAllThemes("mic-priority", size: CGSize(width: 560, height: 200)) {
            MicPriorityList(list: .constant(list), connected: ["laptop", "meeting"]).padding(VedivoxSpace.l)
        }
    }

    /// First run on a clean Mac (#2): models downloading, then the
    /// failure a Mac without network gets — FluidAudio passes URLError through,
    /// so the message is the system's own.
    func testModelLoadingBanner() async throws {
        let state = try await Self.state()
        defer {
            state.isModelLoading = false
            state.modelLoadProgress = nil
            state.modelLoadError = nil
        }
        state.isModelLoading = true
        state.modelLoadProgress = ModelLoadProgress(stage: .transcription, fraction: 0.42)
        try await snapshotAllThemes("model-loading", size: CGSize(width: 720, height: 90)) { ModelLoadingBanner() }
        state.modelLoadError = "The Internet connection appears to be offline."
        try await snapshotAllThemes("model-load-error", size: CGSize(width: 720, height: 90)) { ModelLoadingBanner() }
    }

    /// The first launch of a new build on a large library: the database is
    /// copied and migrated for a minute or more and nothing can be read. The
    /// window says so instead of showing an empty library.
    func testLibraryUpdate() async throws {
        let state = try await Self.state()
        let seeded = state.meetings
        defer {
            state.libraryUpdate = nil
            state.meetings = seeded
        }
        state.meetings = []
        state.libraryUpdate = .backingUp
        try await snapshotAllThemes("library-backup", size: CGSize(width: 720, height: 90)) { ModelLoadingBanner() }
        state.libraryUpdate = .migrating
        try await snapshotAllThemes("library-migration", size: CGSize(width: 720, height: 90)) { ModelLoadingBanner() }
        try await snapshotAllThemes("library-update-sidebar", size: CGSize(width: 300, height: 640)) { SidebarHarness() }
    }

    /// The one-time star card: the seed has four processed meetings, a fifth
    /// in memory crosses StarPrompt.threshold.
    func testStarBanner() async throws {
        let state = try await Self.state()
        let seeded = state.meetings
        defer { state.meetings = seeded }
        state.meetings.append(Meeting(id: "AAAAAAAA-0000-0000-0000-00000000000E", title: "Fifth", startTime: .distantPast,
                                      status: .done))
        UserDefaults.standard.removeObject(forKey: StarPrompt.dismissedKey)
        try await snapshotAllThemes("star-banner", size: CGSize(width: 720, height: 90)) { StarBanner() }
    }

    /// Help → Vedivox Guide as the app renders it, on a fixed excerpt
    /// rather than GUIDE.md itself, which changes with nearly every commit:
    /// a bullet wrapped over source lines, italics across a wrap, a hard-wrapped
    /// paragraph and a fenced code block.
    func testGuide() async throws {
        _ = try await Self.state()
        let source = """
        # Vedivox Guide

        The things Vedivox does that a button label won't tell you. Two minutes to read, and
        this sentence continues on a second source line.

        ## Global hotkeys

        - **⌘⇧2** — start / stop dictation: speak, and the text is typed where your cursor is.
          **Esc** cancels it. *Pause
          playback* is the default.
        - **⌘⇧1** — "Not in transcript" while a meeting is recording.

        ```
        GitHub: гитхаб, гитхап
        Docker: докер, докеру
        ```

        Edits apply to the next processing, no restart needed.
        """
        try await snapshotAllThemes("guide", size: CGSize(width: 520, height: 420)) {
            DescriptionMarkdownView(source: source, onSeek: { _ in }, onCheckboxToggle: { _ in })
                .padding(VedivoxSpace.xl)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The Listen section before its first queue arrives: it says
    /// it is looking, not that there is nothing.
    func testListenLoading() async throws {
        let state = try await Self.state()
        let live = state.listen
        defer { state.listen = live }
        // A queue that does not arrive while the picture is taken.
        state.listen = ListenViewModel(build: { _, _ in
            try await Task.sleep(for: .seconds(3600))
            return []
        }, count: { 0 })
        try await snapshotAllThemes("listen-loading", size: CGSize(width: 900, height: 420)) { ListenView() }
    }

    /// The open drop-down list (VedivoxPicker), drawn without its
    /// popover: the current choice and a highlighted row.
    func testPickerList() async throws {
        _ = try await Self.state()
        try await snapshotAllThemes("picker-list", size: CGSize(width: 220, height: 130)) {
            VedivoxPickerList(options: VedivoxTheme.allCases.map { ($0, $0.label) }, selected: .light, highlighted: 2) { _ in }
                .padding(VedivoxSpace.l)
        }
    }

    /// The transcript's speaker filter, open: a hidden foreign voice
    /// still waiting for its participant-or-background answer, and a speaker
    /// hidden with nothing left to ask.
    func testSpeakerFilterList() async throws {
        _ = try await Self.state()
        func segment(_ id: Int64, _ label: String, hidden: Bool) -> TranscriptSegment {
            TranscriptSegment(id: id, meetingId: Self.meetingId, speakerLabel: label, source: .mic,
                              startTime: 0, endTime: 5, text: "", isExcluded: hidden)
        }
        let segments = [
            segment(1, "Clara Meyer", hidden: false),
            segment(2, "speaker_3", hidden: true),
            segment(3, "speaker_7", hidden: true),
        ]
        let options: [(String?, String)] = [(nil, "All speakers")] + ForeignVoicePolicy
            .speakerFilterTitles(segments, undecided: [segments[1]])
            .map { (String?.some($0.label), $0.title) }
        try await snapshotAllThemes("speaker-filter-list", size: CGSize(width: 380, height: 160)) {
            VedivoxPickerList(options: options, selected: nil, highlighted: 2) { _ in }
                .padding(VedivoxSpace.l)
        }
    }

    // MARK: - Rendering

    private func snapshotAllThemes(
        _ name: String, size: CGSize, file: StaticString = #filePath, testName: String = #function, line: UInt = #line,
        _ make: () -> some View
    ) async throws {
        try await snapshotAllThemes(name, size: size, file: file, testName: testName, line: line) { (make(), { () async in }) }
    }

    /// Renders `make()` once per palette × theme. `adjust` runs after the
    /// view's own `.task` loads, for state those loads would reset.
    private func snapshotAllThemes(
        _ name: String, size: CGSize, file: StaticString = #filePath, testName: String = #function, line: UInt = #line,
        _ make: () -> (some View, () async -> Void)
    ) async throws {
        for palette in VedivoxPalette.allCases {
            for dark in [false, true] {
                try await render(size: size, palette: palette, dark: dark, make, use: { hosting in
                    // SNAPSHOT_DIR=<dir>: references read and recorded there, not in __Snapshots__ — for
                    // side-by-side variants; outside ~/Documents also out of TCC's way, which now and then
                    // refuses xctest a write into the checkout.
                    let directory = ProcessInfo.processInfo.environment["VEDIVOX_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
                    if let failure = verifySnapshot(
                        of: hosting, as: .image(precision: 0.995),
                        named: "\(name)_\(palette.rawValue)_\(dark ? "dark" : "light")",
                        snapshotDirectory: directory, file: file, testName: testName, line: line
                    ) {
                        XCTFail(failure, file: file, line: line)
                    }
                })
            }
        }
    }

    /// Lays `make()` out offscreen in one palette × theme and hands the settled view to `use`
    /// while its window lives. `adjust` runs after the view's own `.task` loads.
    func render(
        size: CGSize, palette: VedivoxPalette, dark: Bool,
        _ make: () -> (some View, () async -> Void), use: (NSView) async throws -> Void
    ) async throws {
        let state = try await Self.state()
        Self.setForThisProcess([
            VedivoxPalette.defaultsKey: palette.rawValue,
            "voxTheme": dark ? VedivoxTheme.dark.rawValue : VedivoxTheme.light.rawValue,
        ])
        let (view, adjust) = make()
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .environment(state)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
            .background(Color.Vedivox.bg))
        hosting.appearance = appearance
        hosting.frame = CGRect(origin: .zero, size: size)
        // Never ordered in: a window only so `.task` and `.onAppear` run.
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.appearance = appearance
        window.contentView = hosting
        // KeyboardShortcuts.Recorder's `isolated deinit` aborts the xctest process
        // (swift_task_deinitOnExecutorMainActorBackDeploy): the views outlive the test.
        defer {
            Self.rendered.append(hosting)
            window.contentView = nil
        }
        try await settle()
        await adjust()
        try await settle()
        try await use(hosting)
    }

    /// Sets defaults in the argument domain: this process's alone, and it
    /// outranks the persistent one. `UserDefaults.standard` here is
    /// com.apple.dt.xctest.tool, one domain for every xctest process on the
    /// Mac, so a snapshot run in another worktree switched this run's palette
    /// between the write and the render (mono_light drawn in Ink).
    static func setForThisProcess(_ values: [String: Any]) {
        let defaults = UserDefaults.standard
        let domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain).merging(values) { $1 }
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    /// Lets the views' async loads finish and SwiftUI lay out.
    func settle(_ milliseconds: Int = 600) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: - Isolation and fixtures

    /// One `AppState` for the whole run, created only once nothing it starts
    /// can reach the live app.
    static func state() async throws -> AppState {
        if let appState { return appState }

        // The live data directory is ~/Library/Application Support/Vedivox. Refuse
        // anything that is not an explicit throwaway directory.
        let root = DataDirectory.root.standardizedFileURL.path
        let live = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DataDirectory.productionDirectoryName).standardizedFileURL.path
        guard root != live, ProcessInfo.processInfo.environment[DataDirectory.environmentKey] != nil else {
            throw XCTSkip("VEDIVOX_DATA_DIR is not set to a throwaway directory (root: \(root)) — run via make test-snapshots")
        }

        // KeyboardShortcuts calls RegisterEventHotKey even when disabled; with no
        // shortcut stored there is nothing to register. These defaults are the
        // xctest tool's, not Vedivox's.
        for entry in AppShortcuts.catalog {
            KeyboardShortcuts.setShortcut(nil, for: entry.name)
        }
        // AppState.init calls OutputMute.restore(), which unmutes whatever
        // device this key names — never the person's speakers from a test.
        UserDefaults.standard.removeObject(forKey: OutputMute.defaultsKey)
        // No Dock icon, no activation, ever.
        NSApplication.shared.setActivationPolicy(.prohibited)
        // The screens print times and dates through TimeZone.current and
        // Locale.current; the references are drawn in UTC−3 (no DST) and US
        // English with Portugal's formats (24 h). Pinned here, not in a scheme,
        // so a CI runner in UTC or a Mac in another zone or language draws the
        // same images, and TEST_RUNNER_TZ cannot override it.
        setenv("TZ", "America/Montevideo", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        setForThisProcess(["AppleLocale": "en_US@rg=ptzzzz", "AppleLanguages": ["en"]])

        try await seed()
        let state = AppState()
        await state.loadMeetings()
        await state.loadSeries()
        await SpeakerHue.reload()
        state.selectedMeetingIds = [meetingId]
        appState = state
        return state
    }

    private static func seed() async throws {
        let speakers = SpeakerRepository()
        let people: [(id: String, name: String, hue: Double, me: Bool, confirmed: Bool)] = [
            ("SPK-CLARA", "Clara Meyer", 250, false, true),
            ("SPK-DANIEL", "Daniel Sherwood", 200, true, true),
            ("SPK-MARK", "Mark Levin", 40, false, true),
            ("SPK-NORA", "Nora Bellini", 300, false, true),
            ("SPK-OTTO", "Otto Ingram", 75, false, false),
        ]
        for person in people {
            var speaker = Speaker(id: person.id, nameEn: person.name, isMe: person.me)
            speaker.hue = person.hue
            speaker.isConfirmed = person.confirmed
            try await speakers.save(speaker)
        }

        let series = SeriesRepository()
        for (id, name, hue) in [("SER-WEEKLY", "Weekly sync", 250.0), ("SER-121", "1:1 Nora", 300), ("SER-DAILY", "Team daily", 150)] {
            var item = MeetingSeries(id: id, name: name)
            item.hue = hue
            item.icon = "link"
            try await series.save(item)
        }

        let meetings = MeetingRepository()
        // Fixed, so the references do not drift with the clock (2026-03-12 13:00 UTC).
        let now = Date(timeIntervalSince1970: 1_773_320_400)
        var main = Meeting(id: meetingId, title: "Weekly sync with design", startTime: now.addingTimeInterval(-3 * 3600),
                           language: "en", seriesId: "SER-WEEKLY", status: .done)
        main.durationSeconds = 2820
        main.description = "Launch moves to Thursday, beta list unchanged.\n\n## Decisions\n- Launch moves to Thursday\n- [ ] Ping the beta group\n\n### Notes\nThe beta list stays as is."
        try await meetings.save(main)
        let others: [(String, String, TimeInterval, MeetingStatus, String?)] = [
            ("AAAAAAAA-0000-0000-0000-00000000000B", "Interview — backend", -26 * 3600, .done, nil),
            ("AAAAAAAA-0000-0000-0000-00000000000C", "1:1 Nora / Daniel", -50 * 3600, .done, "SER-121"),
            ("AAAAAAAA-0000-0000-0000-00000000000D", "Team daily", -74 * 3600, .done, "SER-DAILY"),
        ]
        for (id, title, offset, status, seriesId) in others {
            var meeting = Meeting(id: id, title: title, startTime: now.addingTimeInterval(offset), language: "en",
                                  seriesId: seriesId, status: status)
            meeting.durationSeconds = 1500
            if id.hasSuffix("B") {
                // Starts with a heading: the sidebar preview must show text, not markup.
                meeting.description = "## Summary\n\n- **Strong** on [storage](https://example.com), see [0:42](vediseek://seek?t=42)"
            }
            try await meetings.save(meeting)
        }

        let lines: [(String?, String, Double, Double, String)] = [
            ("SPK-CLARA", "Clara Meyer", 0, 14, "Let’s move the launch to Thursday and keep the beta list as is."),
            ("SPK-DANIEL", "Daniel Sherwood", 14, 31, "Thursday works. I’ll ping the beta group today so nobody is surprised."),
            ("SPK-MARK", "Mark Levin", 31, 44, "Then the release notes go out on Wednesday evening, right after the freeze."),
            (nil, "Speaker 5", 44, 49, "Pizza is here."),
            ("SPK-NORA", "Nora Bellini", 49, 70, "One more thing: the onboarding copy still says the old price. I can fix it before Thursday."),
            ("SPK-CLARA", "Clara Meyer", 70, 82, "Great, then we are done for today."),
        ]
        try await meetings.saveSegments(lines.map { line in
            var segment = TranscriptSegment(meetingId: meetingId, speakerId: line.0, speakerLabel: line.1,
                                            source: line.0 == "SPK-DANIEL" ? .mic : .system,
                                            startTime: line.2, endTime: line.3, text: line.4)
            segment.confidence = line.0 == nil ? 0.6 : 0.93
            return segment
        })
        // Speaker ↔ meeting links, so the Speakers and Series counts are not all zero.
        for line in lines {
            guard let speakerId = line.0 else { continue }
            try await speakers.assignSpeakerToMeeting(meetingId: meetingId, speakerId: speakerId, diarizationLabel: line.1)
        }
        // Chips come from speakers with a line in the meeting, not from the link alone.
        try await meetings.saveSegments([
            TranscriptSegment(meetingId: "AAAAAAAA-0000-0000-0000-00000000000C", speakerId: "SPK-NORA",
                              speakerLabel: "Nora Bellini", source: .system, startTime: 0, endTime: 9, text: "How was the week?"),
            TranscriptSegment(meetingId: "AAAAAAAA-0000-0000-0000-00000000000C", speakerId: "SPK-DANIEL",
                              speakerLabel: "Daniel Sherwood", source: .mic, startTime: 9, endTime: 20, text: "Busy, mostly the launch."),
        ])
        for speakerId in ["SPK-NORA", "SPK-DANIEL"] {
            try await speakers.assignSpeakerToMeeting(
                meetingId: "AAAAAAAA-0000-0000-0000-00000000000C", speakerId: speakerId, diarizationLabel: nil
            )
        }
    }
}

/// Owners for the focus binding the screens take from `ContentView`.
private struct SidebarHarness: View {
    @FocusState private var focus: MainFocus?
    var body: some View { SidebarView(focus: $focus) }
}

/// Real sidebar rows, newest first: the first open, the second hovered.
private struct SidebarRowsHarness: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        let meetings = appState.meetings.sorted { $0.startTime > $1.startTime }
        VStack(spacing: VedivoxSpace.xxs) {
            ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                SidebarMeetingRow(meeting: meeting,
                                  seriesName: appState.meetingSeries.first { $0.id == meeting.seriesId }?.name,
                                  active: index == 0, onSelect: {})
                    .environment(\.vedivoxRowHovered, index == 1)
                    .padding(.horizontal, VedivoxSpace.s)
            }
        }
        .padding(.vertical, VedivoxSpace.m)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.Vedivox.bgSidebar)
    }
}

private struct SplitHarness: View {
    var mode: SplitTrimSheet.Mode = .split
    @Environment(AppState.self) private var appState
    @State private var viewModel = MeetingDetailViewModel()
    @State private var loaded = false
    var body: some View {
        Group {
            if loaded, let meeting = appState.meetings.first(where: { $0.id == "AAAAAAAA-0000-0000-0000-00000000000A" }) {
                SplitTrimSheet(meeting: meeting, viewModel: viewModel, mode: mode)
            }
        }
        .task {
            await viewModel.load(meetingId: "AAAAAAAA-0000-0000-0000-00000000000A")
            // Mid-way through the third segment: the cut must open at its start.
            if viewModel.segments.count > 2 {
                let third = viewModel.segments[2]
                viewModel.playback.currentTime = (third.startTime + third.endTime) / 2
            }
            loaded = true
        }
    }
}

struct TranscriptHarness: View {
    let viewModel: MeetingDetailViewModel
    let editMode: Bool
    @FocusState private var focus: MainFocus?
    var body: some View {
        TranscriptView(meetingId: "AAAAAAAA-0000-0000-0000-00000000000A", focus: $focus, viewModel: viewModel,
                       editMode: editMode)
    }
}
