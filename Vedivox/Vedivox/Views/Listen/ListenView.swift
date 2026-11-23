import SwiftUI

/// Voices to check by ear (listen-queue § 7): one decision per voice of a
/// meeting, from the keyboard.
struct ListenView: View {
    @Environment(AppState.self) private var appState
    /// Lives in `AppState`, not here: the last list survives leaving the section.
    private var viewModel: ListenViewModel { appState.listen }

    /// Inline entry for «new person» (N) or «other speaker» (/).
    private enum Entry { case newName, search }
    @State private var entry: Entry?
    @State private var entryText = ""
    @State private var confirmed: [Speaker] = []
    @FocusState private var entryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.Vedivox.lineSoft)
            content
            if let outcome = viewModel.outcome {
                Divider().background(Color.Vedivox.lineSoft)
                Text(outcome)
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, VedivoxSpace.l)
                    .padding(.vertical, VedivoxSpace.s)
                    .accessibilityIdentifier("listen.outcome")
            }
        }
        .mainFocusTarget()
        .simultaneousGesture(TapGesture().onEnded {
            if entry == nil { _ = DetailFocusAnchor.takeUnlessClickInEditor() }
        })
        .onKeyPress(.space) { key { viewModel.togglePlay() } }
        .onKeyPress(.leftArrow) { key { viewModel.moveFragment(by: -1) } }
        .onKeyPress(.rightArrow) { key { viewModel.moveFragment(by: 1) } }
        .onKeyPress(.upArrow) { key { viewModel.moveItem(by: -1) } }
        .onKeyPress(.downArrow) { key { viewModel.moveItem(by: 1) } }
        .onKeyPress(characters: Self.actionKeys) { press in
            // ⌥-digits are buttons with their own shortcut below.
            guard press.modifiers.isEmpty, let character = press.characters.first else { return .ignored }
            return key { action(for: character) }
        }
        .task {
            // A return shows the last list at once; the queue is rebuilt behind it.
            appState.screenOpen?.checkpoint("mount, shown \(viewModel.items.count)")
            let filter = appState.listenMeetingFilter
            appState.listenMeetingFilter = nil
            await viewModel.open(meetingFilter: filter)
            appState.screenOpen?.checkpoint("queue \(viewModel.items.count)")
            appState.screenOpen?.finishAfterPaint()
        }
        .onDisappear { viewModel.leave() }
    }

    private static let actionKeys = CharacterSet(charactersIn: "123nNsSoO/")

    /// Keys act only while the region holds the keyboard — never while the
    /// caret is in the name or search field (`keyboard-input`).
    private func key(_ action: () -> Void) -> KeyPress.Result {
        guard entry == nil, DetailFocusAnchor.ownsKeys() else { return .ignored }
        action()
        return .handled
    }

    private func action(for character: Character) {
        switch character {
        case "1", "2", "3":
            let index = Int(String(character))! - 1
            Task { await viewModel.assignCandidate(index) }
        case "n", "N": open(.newName)
        case "/": open(.search)
        case "s", "S": Task { await viewModel.skip() }
        case "o", "O": openInMeeting()
        default: break
        }
    }

    private func open(_ kind: Entry) {
        guard viewModel.selected != nil else { return }
        entryText = ""
        entry = kind
        entryFocused = true
        if kind == .search {
            Task { confirmed = await viewModel.confirmedSpeakers() }
        }
    }

    private func closeEntry() {
        entry = nil
        entryFocused = false
        DetailFocusAnchor.take()
    }

    private func openInMeeting() {
        guard let fragment = viewModel.fragment ?? viewModel.selected?.anchor else { return }
        viewModel.leave()
        appState.pendingSeekTime = fragment.start
        appState.selectedMeetingId = fragment.meetingId
    }

    // MARK: Header

    private var header: some View {
        @Bindable var viewModel = viewModel
        return HStack(spacing: VedivoxSpace.m) {
            Text("Listen")
                .vedivoxFont(.title)
            if viewModel.isLoaded {
                Text("\(viewModel.items.count) voices · \(Self.duration(viewModel.totalSeconds)) unnamed")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
            Spacer()
            Menu(filterTitle) {
                Button("All meetings") { setFilter(nil) }
                Divider()
                ForEach(viewModel.meetings, id: \.id) { meeting in
                    Button(meeting.title) { setFilter(meeting.id) }
                }
            }
            .fixedSize()
            .accessibilityIdentifier("listen.filter")
            Toggle("Skipped", isOn: $viewModel.showSkipped)
                .toggleStyle(.checkbox)
                .onChange(of: viewModel.showSkipped) { _, _ in
                    viewModel.selectedId = nil
                    Task { await viewModel.reload() }
                }
        }
        .padding(.horizontal, VedivoxSpace.l)
        .padding(.vertical, VedivoxSpace.m)
    }

    private var filterTitle: String {
        guard let id = viewModel.meetingFilter else { return "All meetings" }
        return viewModel.meetings.first { $0.id == id }?.title ?? "One meeting"
    }

    private func setFilter(_ id: String?) {
        viewModel.meetingFilter = id
        viewModel.selectedId = nil
        Task { await viewModel.reload() }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if viewModel.items.isEmpty, !viewModel.isLoaded {
            // No queue has arrived yet: «nothing» would be a guess.
            VStack(spacing: VedivoxSpace.m) {
                ProgressView().controlSize(.small)
                Text("Looking for voices…")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("listen.loading")
        } else if viewModel.items.isEmpty {
            ContentUnavailableView(
                viewModel.showSkipped ? "No skipped voices" : "Nothing to listen to",
                systemImage: "ear",
                description: Text("Unnamed voices that sound like a known person, or recur in several meetings, appear here after processing.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: VedivoxSpace.xs) {
                        ForEach(viewModel.items) { item in
                            row(item).id(item.id)
                        }
                    }
                    .padding(VedivoxSpace.m)
                }
                .onChange(of: viewModel.selectedId) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private func row(_ item: ListenQueueItem) -> some View {
        let isSelected = item.id == viewModel.selectedId
        return VStack(alignment: .leading, spacing: VedivoxSpace.s) {
            Button {
                viewModel.select(item.id)
            } label: {
                HStack(spacing: VedivoxSpace.m) {
                    Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                    Text("\(item.heading) · \(Self.duration(item.seconds))")
                        .vedivoxFont(.row)
                        .lineLimit(1)
                    Spacer(minLength: VedivoxSpace.m)
                    if let best = item.candidates.first {
                        Text("best \(Self.similarity(best.similarity)) \(best.name)")
                            .vedivoxFont(.caption)
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, VedivoxSpace.xs)
                .padding(.horizontal, VedivoxSpace.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.vedivoxRow(active: isSelected))
            .accessibilityIdentifier("listen.item")

            if isSelected { details(item) }
        }
    }

    // MARK: Selected item

    private func details(_ item: ListenQueueItem) -> some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.m) {
            if let fragment = viewModel.fragment {
                VStack(alignment: .leading, spacing: VedivoxSpace.xs) {
                    HStack(spacing: VedivoxSpace.m) {
                        Button { viewModel.togglePlay() } label: {
                            Image(systemName: viewModel.player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.vedivoxIcon)
                        .help("Play / pause (Space)")
                        Text("\(formatClock(fragment.start)) – \(formatClock(fragment.end)) · \(fragment.track.rawValue)")
                            .vedivoxFont(.timecode)
                        Spacer()
                        fragmentStep(-1, icon: "chevron.left", help: "Previous fragment (←)")
                        Text("fragment \(viewModel.fragmentIndex + 1) / \(item.fragments.count)")
                            .vedivoxFont(.caption)
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                        fragmentStep(1, icon: "chevron.right", help: "Next fragment (→)")
                    }
                    Text("«\(fragment.text)»")
                        .vedivoxFont(.transcript)
                        .lineLimit(3)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }
                .padding(VedivoxSpace.m)
                .background(Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.m))
            }

            ForEach(Array(item.candidates.enumerated()), id: \.offset) { index, candidate in
                HStack(spacing: VedivoxSpace.m) {
                    Button("\(index + 1)  \(candidate.name)") {
                        Task { await viewModel.assignCandidate(index) }
                    }
                    .buttonStyle(.vedivoxGhost)
                    .help("This is \(candidate.name) (\(index + 1))")
                    Text(Self.similarity(candidate.similarity))
                        .vedivoxFont(.tabular)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                    Spacer()
                    Button("⌥\(index + 1) ▶ hear") { viewModel.hearCandidate(index) }
                        .buttonStyle(.vedivoxGhost)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .option)
                        .disabled(candidate.sample == nil)
                        .help(candidate.sample == nil ? "No line of theirs in another meeting" : "Their longest line in their latest other meeting")
                }
            }

            if let entry {
                entryField(entry)
            } else {
                HStack(spacing: VedivoxSpace.m) {
                    Button("N  New person…") { open(.newName) }.buttonStyle(.vedivoxGhost)
                    Button("/  Other speaker…") { open(.search) }.buttonStyle(.vedivoxGhost)
                    Button("S  Skip") { Task { await viewModel.skip() } }.buttonStyle(.vedivoxGhost)
                    Button("O  Open in meeting") { openInMeeting() }.buttonStyle(.vedivoxGhost)
                }
                .disabled(viewModel.isApplying)
            }
        }
        .padding(.leading, VedivoxSpace.xl)
        .padding(.vertical, VedivoxSpace.s)
    }

    /// The fragment navigator's arrows: the pointer's way to what ← → do.
    private func fragmentStep(_ step: Int, icon: String, help: String) -> some View {
        let enabled = viewModel.canMoveFragment(by: step)
        return Button { viewModel.moveFragment(by: step) } label: { Image(systemName: icon) }
            .buttonStyle(.vedivoxIcon)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityIdentifier(step < 0 ? "listen.fragment.previous" : "listen.fragment.next")
    }

    private func entryField(_ kind: Entry) -> some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.xs) {
            TextField(kind == .newName ? "Name, Return to apply" : "Search confirmed speakers", text: $entryText)
                .vedivoxField()
                .focused($entryFocused)
                .onSubmit { submit(kind) }
                .onExitCommand { closeEntry() }
                .accessibilityIdentifier("listen.entry")
            if kind == .search {
                ForEach(matches.prefix(6), id: \.id) { speaker in
                    Button(speaker.displayName) {
                        closeEntry()
                        Task { await viewModel.assign(.existing(speakerId: speaker.id)) }
                    }
                    .buttonStyle(.vedivoxGhost)
                }
            }
        }
    }

    private var matches: [Speaker] {
        let query = entryText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return confirmed }
        return confirmed.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.nameEn.localizedCaseInsensitiveContains(query)
        }
    }

    private func submit(_ kind: Entry) {
        let text = entryText.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .newName:
            guard !text.isEmpty else { return }
            closeEntry()
            Task { await viewModel.assign(.new(name: text)) }
        case .search:
            guard let first = matches.first else { return }
            closeEntry()
            Task { await viewModel.assign(.existing(speakerId: first.id)) }
        }
    }

    // MARK: Formatting

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600)h \(total % 3600 / 60)m" }
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }

    static func similarity(_ value: Float) -> String { String(format: "%.2f", value) }

    private func formatClock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
