import AppKit
import SwiftUI

/// ⌘K: one field over meetings, series, speakers, screens and menu commands
/// Enter hands the chosen row to `onPick`; the caller closes the
/// sheet first and runs it after, so a command that opens a panel or a sheet
/// of its own does not collide with this one going away.
struct CommandPaletteView: View {
    /// Menu commands; nil reads them from the app's menus on appear.
    var menuCommands: [PaletteItem]?
    var initialQuery = ""
    let onPick: (PaletteItem) -> Void
    let onCancel: () -> Void

    /// The menu item that opens the palette, left out of its own list.
    static let menuTitle = "Quick Search\u{2026}"

    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var commands: [PaletteItem] = []
    @State private var speakers: [Speaker] = []
    @State private var transcriptIds: Set<String> = []
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: VedivoxSpace.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                TextField("Search meetings, speakers, series and commands", text: $query)
                    .textFieldStyle(.plain)
                    .vedivoxFont(.body)
                    .focused($fieldFocused)
                    .accessibilityIdentifier("palette.search")
                    .onKeyPress(.downArrow) { move(1, in: results) }
                    .onKeyPress(.upArrow) { move(-1, in: results) }
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }
                    .onSubmit {
                        if results.indices.contains(highlighted) { onPick(results[highlighted]) }
                    }
            }
            .padding(VedivoxSpace.l)

            Divider().background(Color.Vedivox.lineSoft)

            if results.isEmpty {
                Text("No matches")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: VedivoxSpace.xxs) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                row(item, active: index == highlighted)
                                    .id(item.id)
                            }
                        }
                        .padding(VedivoxSpace.s)
                    }
                    .onChange(of: highlighted) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
        }
        .frame(width: 600, height: 420)
        .background(Color.Vedivox.bg)
        .onAppear {
            query = initialQuery
            commands = menuCommands ?? appMenuCommands()
            fieldFocused = true
        }
        .task { await loadSpeakers() }
        .onChange(of: query) { _, _ in highlighted = 0 }
        // The sidebar's transcript search, debounced the same way; restarts on every keystroke.
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else {
                transcriptIds = []
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let ids = (try? await MeetingRepository().meetingIds(matching: trimmed)) ?? []
            guard !Task.isCancelled else { return }
            transcriptIds = ids
        }
    }

    private func row(_ item: PaletteItem, active: Bool) -> some View {
        Button { onPick(item) } label: {
            HStack(spacing: VedivoxSpace.m) {
                Image(systemName: item.icon)
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                Text(item.title)
                    .vedivoxFont(.row)
                    .foregroundStyle(Color.Vedivox.fg)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: VedivoxSpace.m)
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }
                Text(item.kind.rawValue)
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
            .padding(.vertical, VedivoxSpace.xs)
            .padding(.horizontal, VedivoxSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.vedivoxRow(active: active))
    }

    private func move(_ step: Int, in results: [PaletteItem]) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        highlighted = min(max(highlighted + step, 0), results.count - 1)
        return .handled
    }

    // MARK: - Items

    /// Title matches in the order meetings (newest first), series, speakers,
    /// screens, commands; then meetings found only in the transcript.
    private var results: [PaletteItem] {
        let meetings = appState.meetings.sorted { $0.startTime > $1.startTime }
        let items = meetings.map(meetingItem) + seriesItems + speakerItems + screenItems + commands
        let matched = CommandPalette.filter(items, query: query)
        let titleHits = Set(matched.map(\.id))
        let inTranscript = meetings
            .filter { transcriptIds.contains($0.id) && !titleHits.contains("meeting:\($0.id)") }
            .map { meeting in
                var item = meetingItem(meeting)
                item.subtitle = "in the transcript"
                return item
            }
        return matched + inTranscript
    }

    private func meetingItem(_ meeting: Meeting) -> PaletteItem {
        PaletteItem(
            id: "meeting:\(meeting.id)", kind: .meeting, title: meeting.title,
            subtitle: meeting.startTime.formatted(date: .abbreviated, time: .shortened), icon: "waveform"
        ) { [appState] in
            appState.view = .meetings
            appState.selectedMeetingIds = [meeting.id]
            appState.revealInSidebarRequest += 1
        }
    }

    private var seriesItems: [PaletteItem] {
        appState.meetingSeries.map { series in
            PaletteItem(id: "series:\(series.id)", kind: .series, title: series.name, icon: series.icon ?? "link") { [appState] in
                appState.selectedSeriesId = series.id
                appState.view = .series
            }
        }
    }

    private var speakerItems: [PaletteItem] {
        speakers.map { speaker in
            PaletteItem(
                id: "speaker:\(speaker.id)", kind: .speaker, title: speaker.displayName,
                aliases: [speaker.nameEn, speaker.nickname, speaker.nameRu].compactMap { $0 },
                icon: "person"
            ) { [appState] in
                appState.selectedSpeakerId = speaker.id
                appState.view = .speakers
            }
        }
    }

    /// The sidebar's screens and every Settings section.
    private var screenItems: [PaletteItem] {
        let screens: [(AppState.SidebarView, String, String)] = [
            (.meetings, "All Meetings", "list.bullet"), (.speakers, "Speakers", "person.2"),
            (.listen, "Listen", "ear"), (.series, "Series", "link"),
            (.dictations, "Dictations", "mic"), (.settings, "Settings", "gearshape"),
        ]
        let main = screens.map { view, title, icon in
            PaletteItem(id: "screen:\(view.rawValue)", kind: .command, title: "Go to \(title)", icon: icon) { [appState] in
                appState.view = view
            }
        }
        let settings = SettingsView.Section.allCases.map { section in
            PaletteItem(id: "settings:\(section.rawValue)", kind: .command, title: "Settings: \(section.label)",
                        icon: section.icon) { [appState] in
                appState.settingsSection = section
                appState.view = .settings
            }
        }
        return main + settings
    }

    /// The main menu and the menu bar item's menu, read now: their items and
    /// enabled states follow the app (Stop Recording only while recording).
    private func appMenuCommands() -> [PaletteItem] {
        let skipping = [NSApp.servicesMenu, NSApp.windowsMenu].compactMap { $0 }
        // Settings… is the Settings screen above; Open Vedivox is this window.
        let excluded: Set<String> = [Self.menuTitle, "Settings\u{2026}", "Open Vedivox"]
        var seen: Set<String> = []
        // An item in two menus (Vedivox N Is Available…) is one row.
        return [NSApp.mainMenu, appState.menuBarController.statusMenu].compactMap { $0 }
            .flatMap { CommandPalette.commands(in: $0, skipping: skipping, excludingTitles: excluded) }
            .filter { seen.insert($0.id).inserted }
    }

    private func loadSpeakers() async {
        let all = (try? await SpeakerRepository().all()) ?? []
        // As on the Speakers screen: diarization labels («Speaker 3») are not people.
        speakers = all.filter { !$0.isAutoGenerated }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
