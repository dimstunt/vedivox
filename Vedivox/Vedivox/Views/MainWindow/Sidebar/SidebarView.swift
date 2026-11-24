import AppKit
import SwiftUI

struct SidebarView: View {
    /// Owned by `ContentView` — the search field is one of two places focus can
    /// live, and the other one is in the detail column.
    var focus: FocusState<MainFocus?>.Binding

    @Environment(AppState.self) private var appState

    @State private var searchText: String = ""
    @State private var filterOpen: Bool = false
    @State private var ftsIds: Set<String> = []
    @State private var ftsTask: Task<Void, Never>?
    @State private var anchorId: String?

    @State private var allSpeakers: [Speaker] = []
    @State private var recentSpeakerIds: [String] = []
    @State private var meetingSpeakers: [String: Set<String>] = [:]
    /// Shared with the Speakers page («Показать встречи» sets it) — see AppState.
    private var selectedSpeakerIds: Set<String> { appState.sidebarSpeakerFilterIds }

    private var speakerFilterBinding: Binding<Set<String>> {
        Binding(
            get: { appState.sidebarSpeakerFilterIds },
            set: { appState.sidebarSpeakerFilterIds = $0 }
        )
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            header

            Divider().background(Color.Vedivox.lineSoft)

            ScrollViewReader { proxy in ScrollView {
                VStack(alignment: .leading, spacing: VedivoxSpace.m) {
                    SidebarNav(
                        selection: $appState.view,
                        listenCount: appState.listen.count,
                        seriesCount: appState.meetingSeries.isEmpty ? nil : appState.meetingSeries.count,
                        // Was hardcoded nil while dictations had no storage —
                        // the count is real now.
                        dictationCount: appState.dictations.isEmpty ? nil : appState.dictationTotal
                    )
                    .padding(.horizontal, VedivoxSpace.s)

                    meetingSection
                }
                .padding(.vertical, VedivoxSpace.m)
            }
            .onChange(of: appState.revealInSidebarRequest) { reveal(in: proxy) } }
            .overlay(alignment: .bottomTrailing) { revealButton }
        }
        .background(Color.Vedivox.bgSidebar)
        .onChange(of: searchText) { _, newValue in
            scheduleFTSSearch(newValue)
        }
        .task { await loadSpeakerData() }
        .onChange(of: appState.meetings.count) { _, _ in
            Task { await loadSpeakerData() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: VedivoxSpace.m) {
            SidebarRecordingBlock(recordingVM: appState.recordingVM)

            HStack(spacing: VedivoxSpace.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                TextField("Search meetings", text: $searchText)
                    .textFieldStyle(.plain)
                    .vedivoxFont(.row)
                    .focused(focus, equals: .search)
                    .accessibilityIdentifier("sidebar.search")
                    // On the field itself, so it fires only while the field has
                    // focus: everywhere else Escape keeps closing sheets and
                    // popovers. Not guarded on `focus == .search` — with the
                    // AppKit anchor holding the keyboard, a click into the field
                    // does not update the binding.
                    .onKeyPress(.escape) {
                        // Clears the query first, like a search field (#6).
                        if searchText.isEmpty { focus.takeDetail() } else { searchText = "" }
                        return .handled
                    }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                    }
                    .buttonStyle(.plain)
                }
                if showsRevealButton(at: .searchField) {
                    RevealInSidebarButton().buttonStyle(.vedivoxIcon)
                }
                Button {
                    filterOpen.toggle()
                } label: {
                    HStack(spacing: VedivoxSpace.xs) {
                        Image(systemName: "line.3.horizontal.decrease.circle\(selectedSpeakerIds.isEmpty && !filterOpen ? "" : ".fill")")
                            .foregroundStyle(selectedSpeakerIds.isEmpty && !filterOpen
                                             ? Color.Vedivox.fgSecondary : Color.Vedivox.accentText)
                        if !selectedSpeakerIds.isEmpty {
                            Text("\(selectedSpeakerIds.count)")
                                .vedivoxFont(.caption)
                                .foregroundStyle(Color.Vedivox.accentFg)
                                .padding(.horizontal, VedivoxSpace.xs)
                                .padding(.vertical, VedivoxSpace.xxs)
                                .background(Color.Vedivox.accent, in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $filterOpen, arrowEdge: .bottom) {
                    SpeakerFilterPopover(
                        allSpeakers: allSpeakers,
                        recentIds: recentSpeakerIds,
                        selectedIds: speakerFilterBinding
                    )
                }
            }
            .padding(.horizontal, VedivoxSpace.m)
            .padding(.vertical, VedivoxSpace.s)
            .background(Color.Vedivox.bgInput, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
        }
        .padding(VedivoxSpace.l)
    }

    // MARK: - Meeting list

    private var meetingSection: some View {
        // how often the list is rebuilt, what it costs, and how many
        // row bodies SwiftUI evaluated since the previous pass (debug logging).
        var trace = PerfTrace("[Sidebar] list pass, row bodies since previous \(SidebarMeetingRow.takeBodyCount())")
        let filtered = filteredMeetings
        trace.checkpoint("sort+filter \(filtered.count)")
        let groups = groupMeetingsByDay(filtered)
        trace.checkpoint("group \(groups.count)")
        let seriesById = Dictionary(uniqueKeysWithValues: appState.meetingSeries.map { ($0.id, $0.name) })
        trace.finish()

        // Lazy: a right-click resolves its row among the built ones, and with
        // all 374 built the menu took 5–50 ms to build (ContextMenuPerfProbe).
        return LazyVStack(alignment: .leading, spacing: VedivoxSpace.m) {
            if groups.isEmpty {
                // Not "No meetings" while the database cannot be read yet.
                Text(appState.libraryUpdate != nil ? "Updating your library…"
                    : searchText.isEmpty ? "No meetings" : "No matches")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                        VedivoxSectionHeader(title: group.label)
                            .padding(.horizontal, VedivoxSpace.s + VedivoxSpace.m) // aligns with row text: row inset + row padding
                            .padding(.top, VedivoxSpace.m)
                            .padding(.bottom, VedivoxSpace.xxs)

                        ForEach(group.meetings) { meeting in
                            SidebarMeetingRow(
                                meeting: meeting,
                                seriesName: meeting.seriesId.flatMap { seriesById[$0] },
                                active: appState.selectedMeetingIds == [meeting.id]
                                    && appState.view == .meetings,
                                onSelect: { handleRowClick(meeting, in: filtered) }
                            )
                            .padding(.horizontal, VedivoxSpace.s)
                            .id(meeting.id)
                        }
                    }
                }
            }
        }
    }

    /// Reveal in Sidebar while a meeting is open, if it sits in the sidebar.
    private func showsRevealButton(at placement: RevealButtonPlacement) -> Bool {
        RevealButtonPlacement.chosen == placement && appState.view == .meetings && appState.selectedMeetingId != nil
    }

    @ViewBuilder private var revealButton: some View {
        if showsRevealButton(at: .listCorner) {
            RevealInSidebarButton()
                .buttonStyle(.vedivoxFloatingIcon)
                .padding(VedivoxSpace.l)
        }
    }

    /// Scrolls to the open meeting; a search or speaker filter that hides it
    /// is cleared first.
    private func reveal(in proxy: ScrollViewProxy) {
        guard let id = appState.selectedMeetingId else { return }
        if !filteredMeetings.contains(where: { $0.id == id }) {
            searchText = ""
            appState.sidebarSpeakerFilterIds = []
        }
        // A turn later: the rows the cleared filter brings back are not laid out yet.
        Task { @MainActor in
            // The list is lazy: a day far down is not built, so its rows have
            // no position yet. Its group is the lazy stack's own child — jump
            // there first, then to the row once it is built.
            let day = groupMeetingsByDay(filteredMeetings).first { $0.meetings.contains { $0.id == id } }?.id
            if let day {
                proxy.scrollTo(day, anchor: .center)
                await Task.yield()
            }
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
    }

    // MARK: - Selection

    private func handleRowClick(_ meeting: Meeting, in ordered: [Meeting]) {
        appState.lastMeetingClick = (meeting.id, CFAbsoluteTimeGetCurrent())
        let flags = NSEvent.modifierFlags
        appState.view = .meetings
        // Picking a meeting is the moment the user stops searching. Without
        // this the field keeps focus after the click, and the player keys go on
        // being typed into it — which is how the search field held every
        // keystroke for the whole life of the window.
        focus.takeDetail()

        if flags.contains(.command) {
            if appState.selectedMeetingIds.contains(meeting.id) {
                appState.selectedMeetingIds.remove(meeting.id)
            } else {
                appState.selectedMeetingIds.insert(meeting.id)
            }
            anchorId = meeting.id
        } else if flags.contains(.shift),
                  let anchor = anchorId,
                  let i = ordered.firstIndex(where: { $0.id == anchor }),
                  let j = ordered.firstIndex(where: { $0.id == meeting.id }) {
            let range = i <= j ? i ... j : j ... i
            appState.selectedMeetingIds = Set(ordered[range].map(\.id))
        } else {
            appState.selectedMeetingIds = [meeting.id]
            anchorId = meeting.id
        }
    }

    // MARK: - Filtering

    private var filteredMeetings: [Meeting] {
        var result = appState.meetings.sorted { $0.startTime > $1.startTime }
        if !searchText.isEmpty {
            let lower = searchText.lowercased()
            result = result.filter { meeting in
                meeting.title.lowercased().contains(lower)
                    || ftsIds.contains(meeting.id)
            }
        }
        if !selectedSpeakerIds.isEmpty {
            result = result.filter { meeting in
                selectedSpeakerIds.isSubset(of: meetingSpeakers[meeting.id] ?? [])
            }
        }
        return result
    }

    // MARK: - Speaker data loading

    private func loadSpeakerData() async {
        let repo = SpeakerRepository()
        async let speakersCall = try? repo.all()
        async let mapCall = try? repo.meetingSpeakerMap()
        let (speakers, map) = await (speakersCall, mapCall)
        let resolvedSpeakers = speakers ?? []
        let resolvedMap = map ?? [:]

        // People only, as every other speaker list: one anonymous row per voice per meeting is hundreds.
        allSpeakers = resolvedSpeakers.filter { !$0.isAutoGenerated }
        meetingSpeakers = resolvedMap
        let people = Set(allSpeakers.map(\.id))
        recentSpeakerIds = computeRecentSpeakerIds(
            meetings: appState.meetings,
            map: resolvedMap.mapValues { $0.intersection(people) },
            limit: 8
        )
        await SpeakerHue.reload()
    }

    private func computeRecentSpeakerIds(
        meetings: [Meeting],
        map: [String: Set<String>],
        limit: Int
    ) -> [String] {
        let recent = meetings.sorted { $0.startTime > $1.startTime }.prefix(20)
        var counts: [String: Int] = [:]
        for meeting in recent {
            for speakerId in map[meeting.id] ?? [] {
                counts[speakerId, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    private func scheduleFTSSearch(_ query: String) {
        ftsTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            ftsIds = []
            return
        }
        ftsTask = Task { [trimmed] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let ids = (try? await MeetingRepository().meetingIds(matching: trimmed)) ?? []
            guard !Task.isCancelled else { return }
            ftsIds = ids
        }
    }
}
