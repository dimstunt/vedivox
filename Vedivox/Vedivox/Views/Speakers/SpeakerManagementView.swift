import SwiftUI

/// Speakers page: master list + detail pane, per the Claude Design bundle
/// (`other-views.jsx` SpeakersView) —
/// Cmd+F fuzzy search, persistent hue colors with a swatch picker,
/// Cmd+click multi-select for merge and «Показать встречи».
struct SpeakerManagementView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.undoManager) private var undoManager

    /// In AppState, so a return draws the last list at once.
    private var speakerInfos: [SpeakerInfo] {
        get { appState.speakerInfos ?? [] }
        nonmutating set { appState.speakerInfos = newValue }
    }

    /// Kept in AppState so a return to Speakers reopens the same speaker
    /// (screen-state-memory).
    private var selectedSpeakerId: String? {
        get { appState.selectedSpeakerId }
        nonmutating set { appState.selectedSpeakerId = newValue }
    }

    @State private var multiSelection: Set<String> = []
    private var speakerMeetings: [Meeting] { currentMeetings?.meetings ?? [] }
    /// Who else spoke in the selected speaker's meetings; chips narrow the list.
    private var coSpeakers: SpeakerChipFilter { currentMeetings?.coSpeakers ?? SpeakerChipFilter() }
    private var currentMeetings: (speakerId: String, meetings: [Meeting], coSpeakers: SpeakerChipFilter)? {
        appState.speakerMeetings.flatMap { $0.speakerId == selectedSpeakerId ? $0 : nil }
    }

    @State private var coSpeakerSelection: Set<SpeakerChipFilter.Key> = []
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool
    @State private var showingMergePicker = false
    @State private var mergeTargetId: String?
    @State private var profileSpeaker: Speaker?
    @State private var driftAlerts: [SpeakerDriftMonitor.DriftAlert] = []
    @State private var deleteCandidate: SpeakerInfo?
    /// A failed speaker change, shown instead of swallowed.
    @State private var actionError: String?

    private let repo = SpeakerRepository()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.Vedivox.lineSoft)

            // Canonical-collision alerts.
            DriftAlertsBanner(alerts: driftAlerts) { failure in
                actionError = failure
                Task {
                    driftAlerts = await appState.driftAlerts(force: true)
                    await loadSpeakers()
                    appState.transcriptVersion += 1
                }
            }

            if appState.speakerInfos == nil {
                // The first load since launch: an empty ground, not "No Speakers".
                Color.Vedivox.bg.frame(maxHeight: .infinity)
            } else if speakerInfos.isEmpty {
                ContentUnavailableView(
                    "No Speakers",
                    systemImage: "person.2",
                    description: Text("Speakers appear after meetings are recorded and transcribed.")
                )
                .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    listColumn
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    detailColumn
                        .frame(minWidth: 380, maxWidth: .infinity)
                }
            }
        }
        .background(Color.Vedivox.bg)
        .navigationTitle("Speakers")
        .safeAreaInset(edge: .bottom) {
            if !multiSelection.isEmpty {
                selectionBar
            }
        }
        .background(searchShortcut)
        .onKeyPress(.escape) {
            if !multiSelection.isEmpty {
                multiSelection.removeAll()
                return .handled
            }
            return .ignored
        }
        .sheet(isPresented: $showingMergePicker) { mergeSheet }
        .sheet(item: $profileSpeaker) { speaker in profileSheet(speaker) }
        .confirmationDialog(
            deleteCandidate.map { "Delete \u{201C}\($0.speaker.displayName)\u{201D}?" } ?? "",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { info in
            Button("Delete Speaker", role: .destructive) { delete(info.speaker) }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { info in
            Text("""
                Their lines in \(info.meetingCount) meeting\(info.meetingCount == 1 ? "" : "s") become unnamed \
                and Vedivox stops recognising this voice. Edit → Undo brings them back.
                """)
        }
        .alert(
            "Could not change speakers",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task {
            appState.screenOpen?.checkpoint("mount")
            await loadSpeakers()
            appState.screenOpen?.checkpoint("speakers \(speakerInfos.count)")
            appState.screenOpen?.finishAfterPaint()
            driftAlerts = await appState.driftAlerts()
        }
        // initial: a return with the speaker already selected loads its meetings too.
        // Another speaker's meetings are not shown meanwhile: `speakerMeetings` checks the id.
        .onChange(of: selectedSpeakerId, initial: true) { _, newId in
            coSpeakerSelection = []
            guard let newId else { return }
            Task {
                let meetings = (try? await repo.meetingsForSpeaker(newId)) ?? []
                let spoken = try? await repo.spokenLinks(meetingIds: meetings.map(\.id))
                let coSpeakers = SpeakerChipFilter(
                    speakers: spoken?.speakers ?? [],
                    links: (spoken?.links ?? []).filter { $0.speakerId != newId }
                )
                appState.speakerMeetings = (newId, meetings, coSpeakers)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: VedivoxSpace.l) {
            Text("Speakers")
                .vedivoxFont(.header)
                .foregroundStyle(Color.Vedivox.fg)
            Text("\(speakerInfos.count) total")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            Text("\(speakerInfos.filter(\.speaker.isConfirmed).count) confirmed")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            Spacer()
        }
        .padding(.horizontal, VedivoxSpace.xxl)
        .padding(.vertical, VedivoxSpace.l)
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: VedivoxSpace.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                TextField("Search (⌘F)", text: $query)
                    .textFieldStyle(.plain)
                    .vedivoxFont(.row)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, VedivoxSpace.m)
            .padding(.vertical, VedivoxSpace.s)
            .background(Color.Vedivox.bgInput, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
            .padding(VedivoxSpace.l)

            ScrollView {
                LazyVStack(spacing: VedivoxSpace.xxs) {
                    ForEach(filteredInfos, id: \.speaker.id) { info in
                        listRow(info)
                    }
                    if filteredInfos.isEmpty {
                        Text("No matches")
                            .vedivoxFont(.caption)
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                            .padding(.vertical, VedivoxSpace.xxxl)
                    }
                }
                .padding(.horizontal, VedivoxSpace.m)
                .padding(.bottom, VedivoxSpace.m)
            }
        }
        // The list sits on the content ground, not the sidebar's: on bgSidebar it
        // merged with the main sidebar beside it (owner's review, build 1002).
        .background(Color.Vedivox.bg)
    }

    private func listRow(_ info: SpeakerInfo) -> some View {
        let speaker = info.speaker
        let isActive = selectedSpeakerId == speaker.id
        let isChecked = multiSelection.contains(speaker.id)

        return Button {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) {
                if isChecked { multiSelection.remove(speaker.id) } else { multiSelection.insert(speaker.id) }
            } else {
                selectedSpeakerId = speaker.id
            }
        } label: {
            HStack(spacing: VedivoxSpace.m) {
                if isChecked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.Vedivox.accentText)
                        .frame(width: 28, height: 28)
                } else {
                    avatar(speaker, size: 28)
                }
                VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                    HStack(spacing: VedivoxSpace.s) {
                        Text(speaker.displayName)
                            .vedivoxFont(.label)
                            .foregroundStyle(Color.Vedivox.fg)
                            .lineLimit(1)
                        if speaker.isMe { meTag }
                        if !speaker.isConfirmed { unconfirmedTag }
                    }
                    Text("\(info.meetingCount) meeting\(info.meetingCount == 1 ? "" : "s")")
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VedivoxSpace.m)
            .padding(.vertical, VedivoxSpace.s)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: VedivoxRadius.s)
                    .fill(isActive ? Color.Vedivox.bgActive : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !speaker.isMe {
                Button("This is me") {
                    Task {
                        try? await repo.markAsMe(speaker.id)
                        await loadSpeakers()
                    }
                }
            }
            Button("Edit Profile") { profileSpeaker = speaker }
            Menu("Color") {
                ForEach(Self.hueSwatches, id: \.self) { swatch in
                    let current = hue(of: speaker)
                    let isOn = abs(current - swatch) < 15 || abs(current - swatch) > 345
                    if isOn {
                        Button {
                            applyHue(swatch, to: speaker)
                        } label: {
                            Label(Self.hueName(swatch), systemImage: "checkmark")
                        }
                    } else {
                        Button(Self.hueName(swatch)) {
                            applyHue(swatch, to: speaker)
                        }
                    }
                }
            }
            if !speaker.isMe {
                Divider()
                Button("Delete Speaker\u{2026}", role: .destructive) { deleteCandidate = info }
            }
        }
    }

    /// Puts a speaker change on Edit → Undo.
    private func offerUndo(_ undo: SpeakerUndo, named name: String) async {
        await undoManager?.registerSpeakerUndo(undo, named: name) { failure in
            if let failure { appState.speakerUndoFailure = failure }
            await loadSpeakers()
            appState.transcriptVersion += 1
        }
    }

    private func delete(_ speaker: Speaker) {
        deleteCandidate = nil
        Task {
            let undo = try? await SpeakerUndo.capture(speakerIds: [speaker.id])
            let response = await appState.commandDeleteSpeaker(id: speaker.id)
            if !response.ok {
                actionError = response.message
            } else if let undo {
                await offerUndo(undo, named: "Delete Speaker")
            }
            multiSelection.remove(speaker.id)
            await loadSpeakers()
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let info = selectedInfo {
            ScrollView {
                VStack(alignment: .leading, spacing: VedivoxSpace.xxl) {
                    detailHead(info)
                    hueSection(info.speaker)
                    meetingsSection
                }
                .padding(VedivoxSpace.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.Vedivox.bg)
        } else {
            ContentUnavailableView(
                "Select a Speaker",
                systemImage: "person.crop.circle",
                description: Text("Cmd+click for multi-select — merge speakers or filter meetings.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHead(_ info: SpeakerInfo) -> some View {
        let speaker = info.speaker
        return HStack(alignment: .top, spacing: VedivoxSpace.l) {
            avatar(speaker, size: 56)
            VStack(alignment: .leading, spacing: VedivoxSpace.xs) {
                HStack(spacing: VedivoxSpace.s) {
                    Text(speaker.displayName)
                        .vedivoxFont(.header)
                        .foregroundStyle(Color.speaker(hue: hue(of: speaker), scheme: scheme))
                    if speaker.isMe { meTag }
                    if !speaker.isConfirmed { unconfirmedTag }
                }
                HStack(spacing: VedivoxSpace.l) {
                    statItem(value: "\(info.meetingCount)", label: info.meetingCount == 1 ? "meeting" : "meetings")
                    statItem(value: Self.formatDuration(info.totalSpeakingSeconds), label: "speech")
                    if let last = info.lastMeetingDate {
                        statItem(value: last.formatted(date: .abbreviated, time: .omitted), label: "last")
                    }
                }
                if speaker.displayName != speaker.nameEn, !speaker.nameEn.isEmpty {
                    Text(speaker.nameEn)
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: VedivoxSpace.s) {
                Button {
                    profileSpeaker = speaker
                } label: {
                    Label("Edit", systemImage: "person.crop.circle")
                }
                .controlSize(.small)
                if !speaker.isMe {
                    Button {
                        Task {
                            try? await repo.markAsMe(speaker.id)
                            await loadSpeakers()
                        }
                    } label: {
                        Label("This is me", systemImage: "star")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func statItem(value: String, label: String) -> some View {
        HStack(spacing: VedivoxSpace.xs) {
            Text(value)
                .vedivoxFont(.overline)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            Text(label)
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
        }
    }

    // MARK: - Hue picker

    private static let hueSwatches: [Double] = stride(from: 0.0, to: 360.0, by: 30.0).map { $0 }

    /// Human-readable swatch names for the context-menu «Цвет» submenu, where
    /// colored circles can't be rendered (menus strip view tints).
    private static func hueName(_ hue: Double) -> String {
        switch Int(hue) {
        case 0: "Red"
        case 30: "Orange"
        case 60: "Yellow"
        case 90: "Lime"
        case 120: "Green"
        case 150: "Emerald"
        case 180: "Teal"
        case 210: "Cyan"
        case 240: "Blue"
        case 270: "Violet"
        case 300: "Purple"
        case 330: "Pink"
        default: "Hue \(Int(hue))°"
        }
    }

    private func hueSection(_ speaker: Speaker) -> some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.m) {
            Text("COLOR")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            HStack(spacing: VedivoxSpace.s) {
                ForEach(Self.hueSwatches, id: \.self) { swatch in
                    let current = hue(of: speaker)
                    let isOn = abs(current - swatch) < 15 || abs(current - swatch) > 345
                    Button {
                        applyHue(swatch, to: speaker)
                    } label: {
                        Circle()
                            .fill(Color.speaker(hue: swatch, scheme: scheme))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().strokeBorder(
                                    isOn ? Color.Vedivox.fg : Color.Vedivox.line,
                                    lineWidth: isOn ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Hue \(Int(swatch))°")
                }
            }
        }
    }

    private func applyHue(_ hue: Double, to speaker: Speaker) {
        Task {
            try? await repo.updateHue(speaker.id, hue: hue)
            SpeakerHue.set(hue, for: speaker.id)
            await loadSpeakers()
            appState.transcriptVersion += 1
        }
    }

    // MARK: - Meetings section

    private var shownMeetings: [Meeting] {
        coSpeakers.filter(speakerMeetings, selection: coSpeakerSelection)
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.m) {
            if !coSpeakers.chips.isEmpty {
                Text("WITH")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                SpeakerFilterChips(filter: coSpeakers, selection: $coSpeakerSelection)
                    .padding(.bottom, VedivoxSpace.m)
            }
            HStack(spacing: VedivoxSpace.s) {
                Text("MEETINGS")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                Text("\(shownMeetings.count)")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgQuaternary)
            }
            if shownMeetings.isEmpty, !coSpeakerSelection.isEmpty {
                Text("No meeting has this speaker together with all the selected ones.")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
            VStack(spacing: VedivoxSpace.xxs) {
                ForEach(shownMeetings) { meeting in
                    Button {
                        appState.selectedMeetingIds = [meeting.id]
                        appState.view = .meetings
                    } label: {
                        HStack(spacing: VedivoxSpace.m) {
                            Image(systemName: "waveform")
                                .vedivoxFont(.caption)
                                .foregroundStyle(Color.Vedivox.fgSecondary)
                            Text(meeting.title)
                                .vedivoxFont(.row)
                                .foregroundStyle(Color.Vedivox.fg)
                                .lineLimit(1)
                            Spacer()
                            Text(meeting.startTime.formatted(date: .abbreviated, time: .shortened))
                                .vedivoxFont(.caption)
                                .foregroundStyle(Color.Vedivox.fgSecondary)
                        }
                        .padding(.horizontal, VedivoxSpace.m)
                        .padding(.vertical, VedivoxSpace.s)
                        .contentShape(Rectangle())
                        .background(Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Multi-selection bar

    private var selectionBar: some View {
        HStack(spacing: VedivoxSpace.l) {
            Text("\(multiSelection.count) selected")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)

            if multiSelection.count >= 2 {
                Button {
                    // List order, not Set order: the default must not change between opens.
                    mergeTargetId = speakerInfos.first { multiSelection.contains($0.speaker.id) }?.speaker.id
                    showingMergePicker = true
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.vedivoxProminent)
            }

            Button {
                appState.sidebarSpeakerFilterIds = multiSelection
                appState.view = .meetings
            } label: {
                Label("Show Meetings", systemImage: "line.3.horizontal.decrease.circle")
            }
            .controlSize(.small)
            .help("Filter the sidebar to meetings where all selected speakers take part")

            Spacer()

            Button("Clear") { multiSelection.removeAll() }
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, VedivoxSpace.m)
        .background(.bar)
    }

    // MARK: - Sheets

    private var mergeSheet: some View {
        MergeSpeakerPicker(
            speakers: speakerInfos.filter { multiSelection.contains($0.speaker.id) },
            targetId: $mergeTargetId,
            onMerge: { targetId in
                Task {
                    let sourceIds = Array(multiSelection.filter { $0 != targetId })
                    do {
                        let undo = try await SpeakerUndo.capture(speakerIds: sourceIds, rows: [targetId])
                        try await repo.mergeSpeakers(targetId: targetId, sourceIds: sourceIds, confirmTarget: true)
                        await offerUndo(undo, named: "Merge Speakers")
                        multiSelection.removeAll()
                        selectedSpeakerId = targetId
                    } catch {
                        Log.error("Merge into \(targetId) failed: \(error)")
                        actionError = "Merge failed: \(error.localizedDescription)"
                    }
                    await loadSpeakers()
                    appState.transcriptVersion += 1
                }
                showingMergePicker = false
            },
            onCancel: { showingMergePicker = false }
        )
    }

    private func profileSheet(_ speaker: Speaker) -> some View {
        SpeakerProfileSheet(
            speaker: speaker,
            others: speakerInfos.map(\.speaker),
            onSave: { nameEn, nickname, nameRu in
                Task {
                    do {
                        let undo = try await SpeakerUndo.capture(speakerIds: [speaker.id])
                        try await repo.updateProfile(
                            speaker.id, nameEn: nameEn, nameRu: nameRu, nickname: nickname
                        )
                        await offerUndo(undo, named: "Rename Speaker")
                    } catch {
                        Log.error("Saving speaker \(speaker.id) failed: \(error)")
                        actionError = "Could not save the profile: \(error.localizedDescription)"
                    }
                    await loadSpeakers()
                    appState.transcriptVersion += 1
                }
                profileSpeaker = nil
            },
            onMerge: { targetId in
                profileSpeaker = nil
                Task {
                    do {
                        let undo = try await SpeakerUndo.capture(speakerIds: [speaker.id], rows: [targetId])
                        try await repo.mergeSpeakers(targetId: targetId, sourceIds: [speaker.id], confirmTarget: true)
                        await offerUndo(undo, named: "Merge Speakers")
                        selectedSpeakerId = targetId
                    } catch {
                        Log.error("Merge \(speaker.id) into \(targetId) failed: \(error)")
                        actionError = "Merge failed: \(error.localizedDescription)"
                    }
                    await loadSpeakers()
                    appState.transcriptVersion += 1
                }
            },
            onCancel: { profileSpeaker = nil }
        )
    }

    // MARK: - Search (⌘F + fuzzy)

    private var searchShortcut: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut(appState.shortcut(.findInView))
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var filteredInfos: [SpeakerInfo] {
        guard !query.isEmpty else { return speakerInfos }
        return speakerInfos.filter { info in
            let speaker = info.speaker
            return [speaker.displayName, speaker.nameEn, speaker.nameRu ?? "", speaker.nickname ?? ""]
                .contains { Self.fuzzyMatches($0, query: query) }
        }
    }

    /// Case-insensitive subsequence match: "алпр" finds "Алиса Примерова".
    static func fuzzyMatches(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var queryIterator = query.lowercased().makeIterator()
        var needle = queryIterator.next()
        for char in text.lowercased() {
            if let current = needle, char == current {
                needle = queryIterator.next()
                if needle == nil { return true }
            }
        }
        return needle == nil
    }

    // MARK: - Helpers

    private var meTag: some View {
        Text("me")
            .vedivoxFont(.caption)
            .foregroundStyle(Color.Vedivox.accentFg)
            .padding(.horizontal, VedivoxSpace.s)
            .padding(.vertical, VedivoxSpace.xxs)
            .background(Color.Vedivox.accent, in: Capsule())
    }

    private var unconfirmedTag: some View {
        Text("unconfirmed")
            .vedivoxFont(.caption)
            .foregroundStyle(Color.Vedivox.warning)
            .padding(.horizontal, VedivoxSpace.s)
            .padding(.vertical, VedivoxSpace.xxs)
            .background(Color.Vedivox.warningSoft, in: Capsule())
    }

    private var selectedInfo: SpeakerInfo? {
        speakerInfos.first { $0.speaker.id == selectedSpeakerId }
    }

    private func hue(of speaker: Speaker) -> Double {
        speaker.hue ?? SpeakerHue.for(speaker.id)
    }

    private func avatar(_ speaker: Speaker, size: CGFloat) -> some View {
        let speakerHue = hue(of: speaker)
        return Text(Self.initials(speaker.displayName))
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(Color.speaker(hue: speakerHue, scheme: scheme))
            .frame(width: size, height: size)
            .background(Color.speakerBg(hue: speakerHue, scheme: scheme), in: Circle())
            .overlay(Circle().strokeBorder(Color.speaker(hue: speakerHue, scheme: scheme).opacity(0.4)))
    }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init)
        return letters.joined().uppercased()
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    private func loadSpeakers() async {
        var trace = PerfTrace("[SpeakersOpen] loadSpeakers")
        // Side by side, and not the view task's to cancel. The list used to
        // queue behind the hue map; both are quick (0–40 ms and ~300 ms), and
        // the one 36 s "hue reload" on record was the database being migrated.
        let speakers = repo
        async let hues: Void = SpeakerHue.reload()
        let loaded = try? await uncancelled { try await speakers.speakersWithMeetingCounts() }
        await hues
        speakerInfos = (loaded ?? []).filter { !$0.speaker.isAutoGenerated }
        trace.checkpoint("speakers and hues")
        // Nothing selected yet, or the remembered speaker was merged / deleted.
        if !speakerInfos.contains(where: { $0.speaker.id == selectedSpeakerId }) {
            selectedSpeakerId = speakerInfos.first?.speaker.id
        }
        trace.finish()
        // Hue backfill is a write — it can wait behind pipeline transactions,
        // so it must never block first render. Refresh colors when it lands.
        if speakerInfos.contains(where: { $0.speaker.hue == nil }) {
            Task {
                try? await repo.assignMissingHues()
                await SpeakerHue.reload()
                speakerInfos = ((try? await repo.speakersWithMeetingCounts()) ?? [])
                    .filter { !$0.speaker.isAutoGenerated }
            }
        }
    }
}

// MARK: - Speaker Profile Sheet

private struct SpeakerProfileSheet: View {
    let speaker: Speaker
    /// The other speakers, for the duplicate-name check.
    let others: [Speaker]
    let onSave: (String, String?, String?) -> Void
    /// Merge this speaker into the record that already has the typed name.
    let onMerge: (String) -> Void
    let onCancel: () -> Void

    @State private var nameEn: String = ""
    @State private var nickname: String = ""
    @State private var nameRu: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.xl) {
            Text("Speaker Profile")
                .vedivoxFont(.bodyStrong)

            Grid(alignment: .leading, horizontalSpacing: VedivoxSpace.l, verticalSpacing: VedivoxSpace.l) {
                GridRow {
                    Text("Name (EN)")
                        .vedivoxFont(.row)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                        .gridColumnAlignment(.trailing)
                    TextField("First Last", text: $nameEn)
                        .vedivoxField()
                }

                GridRow {
                    Text("Nickname")
                        .vedivoxFont(.row)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                    TextField("@handle", text: $nickname)
                        .vedivoxField()
                }

                GridRow {
                    Text("Name (RU)")
                        .vedivoxFont(.row)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                    TextField("First Last", text: $nameRu)
                        .vedivoxField()
                }
            }

            HStack {
                Text("In the transcript:")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                Text(previewDisplayName)
                    .vedivoxFont(.overline)
            }

            switch verdict {
            case .autoLabel:
                Text("Names like speaker_3 are kept for unnamed voices.")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.danger)
            case .taken(_, let name):
                Text("\u{201C}\(name)\u{201D} already has this name. Merge this speaker into them?")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.danger)
            case .ok, .empty:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                if case .taken(let targetId, let name) = verdict {
                    Button("Merge into \u{201C}\(name)\u{201D}") { onMerge(targetId) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Save") {
                        onSave(trimmed(nameEn), optional(nickname), optional(nameRu))
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(verdict != .ok)
                }
            }
        }
        .padding(VedivoxSpace.xxxl)
        .frame(width: 380)
        .onAppear {
            nameEn = speaker.nameEn
            nickname = speaker.nickname ?? ""
            nameRu = speaker.nameRu ?? ""
        }
    }

    private var verdict: SpeakerProfileCheck {
        .check(nameEn: nameEn, nickname: nickname, nameRu: nameRu, speakerId: speaker.id, others: others)
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func optional(_ text: String) -> String? { trimmed(text).isEmpty ? nil : trimmed(text) }

    private var previewDisplayName: String {
        if !trimmed(nameRu).isEmpty { return trimmed(nameRu) }
        if !trimmed(nickname).isEmpty { return trimmed(nickname) }
        return trimmed(nameEn)
    }
}

// MARK: - Merge Speaker Picker

private struct MergeSpeakerPicker: View {
    let speakers: [SpeakerInfo]
    @Binding var targetId: String?
    let onMerge: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: VedivoxSpace.xl) {
            Text("Merge Speakers")
                .vedivoxFont(.bodyStrong)

            Text("Pick the primary speaker. The other selected ones merge into them.")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .multilineTextAlignment(.center)

            Picker("Primary speaker", selection: Binding(
                get: { targetId ?? "" },
                set: { targetId = $0 }
            )) {
                ForEach(speakers, id: \.speaker.id) { info in
                    Text(info.speaker.displayName).tag(info.speaker.id)
                }
            }
            .pickerStyle(.radioGroup)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button("Merge") {
                    if let targetId {
                        onMerge(targetId)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(targetId == nil)
            }
        }
        .padding(VedivoxSpace.xxxl)
        .frame(minWidth: 300)
    }
}
