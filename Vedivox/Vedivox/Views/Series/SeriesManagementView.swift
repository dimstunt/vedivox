import SwiftUI

/// Series page: list + detail pane per the design bundle
/// (`series-dictations.jsx` SeriesView) —
struct SeriesManagementView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme

    /// In AppState, as on Speakers: a return draws the last list at once.
    private var seriesInfos: [SeriesInfo] {
        get { appState.seriesInfos ?? [] }
        nonmutating set { appState.seriesInfos = newValue }
    }

    /// In AppState, as on Speakers: the ⌘K palette opens a series here.
    private var selectedSeriesId: String? {
        get { appState.selectedSeriesId }
        nonmutating set { appState.selectedSeriesId = newValue }
    }

    private var seriesMeetings: [Meeting] { currentDetail?.meetings ?? [] }
    /// Who spoke in which meeting of the series; chips filter the meeting list.
    private var chipFilter: SpeakerChipFilter { currentDetail?.chips ?? SpeakerChipFilter() }
    private var currentDetail: (seriesId: String, meetings: [Meeting], chips: SpeakerChipFilter)? {
        appState.seriesDetail.flatMap { $0.seriesId == selectedSeriesId ? $0 : nil }
    }

    @State private var chipSelection: Set<SpeakerChipFilter.Key> = []
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool
    @State private var editorSeries: MeetingSeries?
    @State private var creatingNew = false
    @State private var deleteCandidate: SeriesInfo?
    /// A failed series change, shown instead of swallowed.
    @State private var actionError: String?

    private let repo = SeriesRepository()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.Vedivox.lineSoft)

            if appState.seriesInfos == nil {
                // The first load since launch: an empty ground, not "No Series".
                Color.Vedivox.bg.frame(maxHeight: .infinity)
            } else if seriesInfos.isEmpty {
                ContentUnavailableView(
                    "No Series",
                    systemImage: "link",
                    description: Text("Series group recurring meetings: 1:1s, syncs, sprints.")
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
        .navigationTitle("Series")
        .background(searchShortcut)
        .sheet(item: $editorSeries) { series in
            SeriesEditorSheet(
                series: series,
                isNew: creatingNew,
                onSave: { updated, retroApply in
                    var saved = updated
                    do {
                        if creatingNew {
                            // A taken name is refused, so the rule, icon and description
                            // typed here are not silently lost to the existing series (#6).
                            let result = try await repo.createOrReuse(updated)
                            guard result.created else {
                                return "A series named “\(result.series.name)” already exists."
                            }
                            saved = result.series
                        } else {
                            try await repo.save(updated)
                        }
                    } catch {
                        // The sheet stays open with the edits; the rule is not applied.
                        Log.error("Saving series \(updated.id) failed: \(error)")
                        return "Could not save the series: \(error.localizedDescription)"
                    }
                    if retroApply {
                        do {
                            _ = try await repo.applyRuleRetroactively(saved)
                        } catch {
                            Log.error("Auto-rule for series \(saved.id) failed: \(error)")
                            actionError = "The series is saved, but its auto-rule was not applied: \(error.localizedDescription)"
                        }
                    }
                    editorSeries = nil
                    creatingNew = false
                    await reload(selecting: saved.id)
                    // Meetings too: the sidebar shows the series names the rule just set.
                    await appState.refreshAfterExternalChange()
                    return nil
                },
                onCancel: {
                    editorSeries = nil
                    creatingNew = false
                }
            )
        }
        .confirmationDialog(
            deleteCandidate.map { "Delete \u{201C}\($0.series.name)\u{201D}?" } ?? "",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { info in
            Button("Delete Series", role: .destructive) { delete(info.series) }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { info in
            Text(info.meetingCount == 0
                ? "The series has no meetings. Its name, icon, description and auto-rule are deleted."
                : "\(info.meetingCount) meeting\(info.meetingCount == 1 ? "" : "s") will be unlinked from it; the meetings stay. Its name, icon, description and auto-rule are deleted.")
        }
        .alert(
            "Could not change series",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task {
            appState.screenOpen?.checkpoint("mount")
            await reload()
            appState.screenOpen?.checkpoint("series \(seriesInfos.count), meetings \(seriesMeetings.count)")
            appState.screenOpen?.finishAfterPaint()
        }
        .onChange(of: selectedSeriesId) { _, newId in
            chipSelection = []
            guard let newId else { return }
            Task { await loadDetail(newId) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: VedivoxSpace.l) {
            Text("Series")
                .vedivoxFont(.header)
                .foregroundStyle(Color.Vedivox.fg)
            Text("\(seriesInfos.count) series")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            let total = seriesInfos.reduce(0) { $0 + $1.meetingCount }
            Text("\(total) meeting\(total == 1 ? "" : "s") in series")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            Spacer()
            Button {
                creatingNew = true
                editorSeries = MeetingSeries(
                    name: "",
                    hue: SpeakerHueMath.nextHue(existing: seriesInfos.compactMap(\.series.hue))
                )
            } label: {
                Label("New Series", systemImage: "plus")
            }
            .controlSize(.small)
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
                    ForEach(filteredInfos, id: \.series.id) { info in
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

    private func listRow(_ info: SeriesInfo) -> some View {
        let series = info.series
        let isActive = selectedSeriesId == series.id

        return Button {
            selectedSeriesId = series.id
        } label: {
            HStack(spacing: VedivoxSpace.m) {
                tile(series, size: 28, iconSize: 12)
                VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                    Text(series.name)
                        .vedivoxFont(.label)
                        .foregroundStyle(Color.Vedivox.fg)
                        .lineLimit(1)
                    Text("\(info.meetingCount) meeting\(info.meetingCount == 1 ? "" : "s")")
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }
                Spacer(minLength: 0)
                if series.autoRulePattern?.isEmpty == false {
                    Image(systemName: "wand.and.stars")
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                        .help("Has an auto-rule")
                }
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
            Button("Configure…") {
                creatingNew = false
                editorSeries = series
            }
            Divider()
            Button("Delete\u{2026}", role: .destructive) { deleteCandidate = info }
        }
    }

    private func delete(_ series: MeetingSeries) {
        deleteCandidate = nil
        Task {
            do {
                try await repo.delete(series)
                if selectedSeriesId == series.id { selectedSeriesId = nil }
            } catch {
                Log.error("Deleting series \(series.id) failed: \(error)")
                actionError = "Could not delete the series: \(error.localizedDescription)"
            }
            await reload()
            await appState.refreshAfterExternalChange()
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let info = selectedInfo {
            ScrollView {
                VStack(alignment: .leading, spacing: VedivoxSpace.xxl) {
                    detailHead(info)
                    if let rule = info.series.autoRulePattern, !rule.isEmpty {
                        ruleChip(rule)
                    }
                    if !chipFilter.chips.isEmpty {
                        participantsSection
                    }
                    meetingsSection
                }
                .padding(VedivoxSpace.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.Vedivox.bg)
        } else {
            ContentUnavailableView(
                "Select a Series",
                systemImage: "link",
                description: Text("Series are listed on the left; right-click to configure or delete.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHead(_ info: SeriesInfo) -> some View {
        let series = info.series
        return HStack(alignment: .top, spacing: VedivoxSpace.l) {
            tile(series, size: 56, iconSize: 22)
            VStack(alignment: .leading, spacing: VedivoxSpace.xs) {
                Text(series.name)
                    .vedivoxFont(.header)
                    .foregroundStyle(Color.speaker(hue: hue(of: series), scheme: scheme))
                HStack(spacing: VedivoxSpace.l) {
                    statItem(value: "\(info.meetingCount)", label: info.meetingCount == 1 ? "meeting" : "meetings")
                    statItem(value: Self.formatDuration(info.totalDurationSeconds), label: "total")
                    statItem(value: "\(chipFilter.speakerCount)", label: "speakers")
                    if let last = info.lastMeetingDate {
                        statItem(value: last.formatted(date: .abbreviated, time: .omitted), label: "last")
                    }
                }
                if let description = series.seriesDescription, !description.isEmpty {
                    Text(description)
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button {
                creatingNew = false
                editorSeries = series
            } label: {
                Label("Configure", systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)
        }
    }

    private func ruleChip(_ rule: String) -> some View {
        HStack(spacing: VedivoxSpace.s) {
            Image(systemName: "wand.and.stars")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            Text("Auto-rule:")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            Text(rule)
                .vedivoxFont(.timecode)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .padding(.horizontal, VedivoxSpace.s)
                .padding(.vertical, VedivoxSpace.xxs)
                .background(Color.Vedivox.bgInput, in: RoundedRectangle(cornerRadius: VedivoxRadius.xs))
                .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.xs).strokeBorder(Color.Vedivox.line))
        }
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.m) {
            sectionTitle("SPEAKERS", count: chipFilter.speakerCount)
            SpeakerFilterChips(filter: chipFilter, selection: $chipSelection)
        }
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.m) {
            let shown = chipFilter.filter(seriesMeetings, selection: chipSelection)
            sectionTitle("MEETINGS", count: shown.count)
            if shown.isEmpty, !chipSelection.isEmpty {
                Text("No meeting of the series has all the selected speakers.")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
            VStack(spacing: VedivoxSpace.xxs) {
                ForEach(shown) { meeting in
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

    private func sectionTitle(_ text: String, count: Int) -> some View {
        HStack(spacing: VedivoxSpace.s) {
            Text(text)
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            Text("\(count)")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgQuaternary)
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

    private func tile(_ series: MeetingSeries, size: CGFloat, iconSize: CGFloat) -> some View {
        let seriesHue = hue(of: series)
        return Image(systemName: series.icon ?? "link")
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(Color.speaker(hue: seriesHue, scheme: scheme))
            .frame(width: size, height: size)
            .background(
                Color.speakerBg(hue: seriesHue, scheme: scheme),
                in: RoundedRectangle(cornerRadius: size * 0.25)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.25)
                    .strokeBorder(Color.speaker(hue: seriesHue, scheme: scheme).opacity(0.4))
            )
    }

    // MARK: - Search / helpers

    private var searchShortcut: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut(appState.shortcut(.findInView))
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var filteredInfos: [SeriesInfo] {
        guard !query.isEmpty else { return seriesInfos }
        return seriesInfos.filter {
            SpeakerManagementView.fuzzyMatches($0.series.name, query: query)
        }
    }

    private var selectedInfo: SeriesInfo? {
        seriesInfos.first { $0.series.id == selectedSeriesId }
    }

    private func hue(of series: MeetingSeries) -> Double {
        series.hue ?? SpeakerHueMath.fallback(series.id)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func reload(selecting: String? = nil) async {
        seriesInfos = (try? await repo.seriesWithStats()) ?? []
        if let selecting {
            selectedSeriesId = selecting
            await loadDetail(selecting)
        } else if selectedSeriesId == nil {
            selectedSeriesId = seriesInfos.first?.series.id
        } else if let current = selectedSeriesId {
            await loadDetail(current)
        }
    }

    private func loadDetail(_ seriesId: String) async {
        let meetings = (try? await repo.meetingsForSeries(seriesId)) ?? []
        let spoken = try? await SpeakerRepository().spokenLinks(meetingIds: meetings.map(\.id))
        let chips = SpeakerChipFilter(speakers: spoken?.speakers ?? [], links: spoken?.links ?? [])
        appState.seriesDetail = (seriesId, meetings, chips)
        // A chip that is gone after a reload must not keep filtering the list to nothing.
        chipSelection = chipSelection.filter { key in chips.chips.contains { $0.key == key } }
    }
}

// MARK: - Editor sheet

private struct SeriesEditorSheet: View {
    let series: MeetingSeries
    let isNew: Bool
    /// Answers with an error text when saving failed; the sheet then stays open.
    let onSave: (MeetingSeries, _ retroApply: Bool) async -> String?
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var icon = "link"
    @State private var hue: Double = 210
    @State private var descriptionText = ""
    @State private var rulePattern = ""
    @State private var retroApply = false
    @State private var saveError: String?
    @State private var saving = false
    /// Series-less meetings the rule would take now.
    @State private var retroCount: Int?

    private static let icons = [
        "link", "person.2", "arrow.triangle.2.circlepath", "target",
        "chart.bar", "lightbulb", "flag", "graduationcap", "wrench.and.screwdriver",
    ]
    private static let hueSwatches: [Double] = stride(from: 0.0, to: 360.0, by: 30.0).map { $0 }

    private var ruleIsValid: Bool {
        rulePattern.isEmpty || SeriesAutoRule.isValidPattern(rulePattern)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.xl) {
            Text(isNew ? "New Series" : "Series Settings")
                .vedivoxFont(.bodyStrong)

            Grid(alignment: .leading, horizontalSpacing: VedivoxSpace.l, verticalSpacing: VedivoxSpace.l) {
                GridRow {
                    label("Name")
                    TextField("1:1 with Alice", text: $name)
                        .vedivoxField()
                }
                GridRow {
                    label("Icon")
                    HStack(spacing: VedivoxSpace.s) {
                        ForEach(Self.icons, id: \.self) { symbol in
                            Button {
                                icon = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 12))
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(icon == symbol ? Color.Vedivox.accentFg : Color.Vedivox.fgSecondary)
                                    .background(
                                        icon == symbol ? Color.Vedivox.accent : Color.Vedivox.bgCard,
                                        in: RoundedRectangle(cornerRadius: VedivoxRadius.s)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                GridRow {
                    label("Color")
                    HStack(spacing: VedivoxSpace.s) {
                        ForEach(Self.hueSwatches, id: \.self) { swatch in
                            let isOn = abs(hue - swatch) < 15 || abs(hue - swatch) > 345
                            Button {
                                hue = swatch
                            } label: {
                                Circle()
                                    .fill(Color.speaker(hue: swatch, scheme: scheme))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(
                                        isOn ? Color.Vedivox.fg : Color.Vedivox.line,
                                        lineWidth: isOn ? 2 : 1
                                    ))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                GridRow {
                    label("Description")
                    TextField("Optional", text: $descriptionText, axis: .vertical)
                        .vedivoxField()
                        .lineLimit(2 ... 4)
                }
                GridRow {
                    label("Auto-rule")
                    VStack(alignment: .leading, spacing: VedivoxSpace.xs) {
                        TextField("regex on the title, e.g. Weekly sync", text: $rulePattern)
                            .vedivoxField()
                            .vedivoxFont(.tabular)
                        if !ruleIsValid {
                            Text("Invalid regex")
                                .vedivoxFont(.caption)
                                .foregroundStyle(Color.Vedivox.danger)
                        } else if !rulePattern.isEmpty {
                            Toggle(
                                retroCount.map { "Apply to \($0) existing meeting\($0 == 1 ? "" : "s") without a series" }
                                    ?? "Apply to existing meetings without a series",
                                isOn: $retroApply
                            )
                            .vedivoxFont(.caption)
                        }
                    }
                }
            }

            if let saveError {
                Text(saveError)
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    var updated = series
                    updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.icon = icon
                    updated.hue = hue
                    updated.seriesDescription = descriptionText.isEmpty ? nil : descriptionText
                    updated.autoRulePattern = rulePattern.isEmpty ? nil : rulePattern
                    let retro = retroApply && !rulePattern.isEmpty
                    saving = true
                    Task {
                        saveError = await onSave(updated, retro)
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !ruleIsValid || saving)
            }
        }
        .task(id: rulePattern) {
            retroCount = nil
            guard !rulePattern.isEmpty, ruleIsValid else { return }
            // Typing pause first: each count reads every series-less meeting title.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            retroCount = try? await SeriesRepository()
                .retroMatches(MeetingSeries(name: "", autoRulePattern: rulePattern)).count
        }
        .padding(VedivoxSpace.xxxl)
        .frame(width: 460)
        .onAppear {
            name = series.name
            icon = series.icon ?? "link"
            hue = series.hue ?? 210
            descriptionText = series.seriesDescription ?? ""
            rulePattern = series.autoRulePattern ?? ""
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .vedivoxFont(.row)
            .foregroundStyle(Color.Vedivox.fgSecondary)
            .gridColumnAlignment(.trailing)
    }
}

// MARK: - Minimal flow layout for participant chips

struct FlowLayoutLite: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
