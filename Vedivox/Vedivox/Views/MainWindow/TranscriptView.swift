import AppKit
import KeyboardShortcuts
import SwiftUI

struct TranscriptView: View {
    let meetingId: String
    /// The window's focus state, owned by `ContentView`. Held here rather than
    /// wrapped from outside because the player keys are delivered through
    /// focus, and `onKeyPress` has to sit on the focused view itself.
    var focus: FocusState<MainFocus?>.Binding

    @Environment(AppState.self) private var appState
    @State private var viewModel: MeetingDetailViewModel

    /// `viewModel` and `editMode` are injectable so the offscreen snapshots can
    /// show a search, a ⌘-selection and a playhead (VedivoxSnapshotTests); the app
    /// passes neither.
    init(meetingId: String, focus: FocusState<MainFocus?>.Binding,
         viewModel: MeetingDetailViewModel = MeetingDetailViewModel(), editMode: Bool = false) {
        self.meetingId = meetingId
        self.focus = focus
        _viewModel = State(initialValue: viewModel)
        _editMode = State(initialValue: editMode)
    }

    /// `true` — per-segment editable list; `false` — Smart run-grouped view.
    /// Session-only (not persisted): edit mode is an intent, not a preference.
    @State private var editMode: Bool
    /// Split/Trim modal.
    @State private var showSplitTrimSheet = false
    @State private var reprocessFailure: String?
    /// Inspector panel open/closed; persisted across launches.
    @AppStorage("inspectorOpen") private var inspectorOpen: Bool = true
    /// Player shortcut keys, editable in Settings → Шорткаты.
    @AppStorage("seekStepSeconds") private var seekStepSeconds = 5.0

    var body: some View {
        HStack(spacing: 0) {
            // What the header actions and the player bar need in one row; a
            // stated minimum lets the split view stop here instead of the row
            // overflowing over the sidebar and clipping the inspector.
            mainColumn
                .frame(minWidth: 560)
            if inspectorOpen {
                Divider()
                InspectorPanel(viewModel: viewModel)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: inspectorOpen)
        .mainFocusTarget()
        // A click on the content takes the keyboard back from a field outside
        // the region (the sidebar search). `simultaneousGesture` so the tap is
        // not consumed — text selection and the context menu below must keep
        // seeing it. The click that focused a text field lands here too, so a
        // click inside the editing field keeps it; a click anywhere else in the
        // region takes the keyboard back to the player.
        .simultaneousGesture(TapGesture().onEnded {
            if DetailFocusAnchor.takeUnlessClickInEditor() { focus.wrappedValue = nil }
        })
        // Player keys, delivered through focus rather than as app-wide key
        // equivalents.
        //
        // The conflict is checked for, not assumed away: a focused text field
        // inside this region (title, transcript search, segment text) is a
        // descendant, and SwiftUI still runs these handlers for its key presses
        // before the field editor sees them — so Space toggled playback and the
        // arrows seeked mid-rename. `playerKey` steps aside whenever
        // the first responder is editable text. As `.keyboardShortcut` these
        // same keys were app-level equivalents that reached the player no
        // matter where the caret was.
        .onKeyPress(.space) {
            playerKey { viewModel.playback.togglePlayPause() }
        }
        .onKeyPress(.leftArrow) {
            playerKey { viewModel.playback.seek(to: viewModel.playback.currentTime - seekStepSeconds) }
        }
        .onKeyPress(.rightArrow) {
            playerKey { viewModel.playback.seek(to: viewModel.playback.currentTime + seekStepSeconds) }
        }
        // The rate shortcuts are user-editable (⌥[ / ⌥] by default), so
        // the key event is matched the way the package records it: key code and
        // modifiers, whatever character ⌥ makes of it on the current layout.
        .onKeyPress(phases: .down) { _ in
            guard let event = NSApp.currentEvent, let pressed = KeyboardShortcuts.Shortcut(event: event) else {
                return .ignored
            }
            if pressed == KeyboardShortcuts.getShortcut(for: .playerSlower) { return playerKey { adjustRate(-1) } }
            if pressed == KeyboardShortcuts.getShortcut(for: .playerFaster) { return playerKey { adjustRate(1) } }
            return .ignored
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    inspectorOpen.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .symbolVariant(inspectorOpen ? .fill : .none)
                }
                .help(inspectorOpen ? "Hide Inspector" : "Show Inspector")
                .keyboardShortcut(appState.shortcut(.toggleInspector))
                .accessibilityIdentifier("toolbar.inspector")
                .accessibilityLabel(inspectorOpen ? "Hide Inspector" : "Show Inspector")
            }
        }
        .sheet(isPresented: $showSplitTrimSheet) {
            if let meeting = viewModel.meeting {
                SplitTrimSheet(meeting: meeting, viewModel: viewModel)
            }
        }
        // «Настройки встречи…» из контекст-меню сайдбара.
        .sheet(isPresented: Binding(
            get: { appState.meetingEditRequestId != nil && appState.meetingEditRequestId == viewModel.meeting?.id },
            set: { if !$0 { appState.meetingEditRequestId = nil } }
        )) {
            if let meeting = viewModel.meeting {
                MeetingEditSheet(meeting: meeting, viewModel: viewModel)
            }
        }
    }

    /// Speaker hue spans for waveform tinting (same hue key as transcript rows).
    private var playerHueSpans: [PlayerBarView.HueSpan] {
        viewModel.segments.compactMap { segment in
            guard segment.speakerLabel != nil || segment.speakerId != nil else { return nil }
            // UNKNOWN is not a persona — leave its bins on the neutral
            // no-speaker color instead of the red-ish hue fallback.
            guard segment.speakerLabel != "UNKNOWN" else { return nil }
            let key = segment.speakerId ?? segment.speakerLabel ?? ""
            return PlayerBarView.HueSpan(
                start: segment.startTime, end: segment.endTime, hue: SpeakerHue.for(key)
            )
        }
    }

    private func adjustRate(_ direction: Int) {
        let presets = PlayerBarView.ratePresets
        let current = viewModel.playback.playbackRate
        let nearest = presets.indices.min(by: {
            abs(presets[$0] - current) < abs(presets[$1] - current)
        }) ?? 1
        let newIndex = min(max(0, nearest + direction), presets.count - 1)
        viewModel.playback.setRate(presets[newIndex])
    }

    /// The single gate every player key passes: the key is the player's only
    /// while the detail anchor holds the keyboard.
    private func playerKey(_ action: () -> Void) -> KeyPress.Result {
        guard DetailFocusAnchor.ownsKeys() else { return .ignored }
        action()
        return .handled
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            // Header
            if let meeting = viewModel.meeting {
                TranscriptHeaderView(
                    meeting: meeting,
                    focus: focus,
                    onRename: { newTitle in
                        Task {
                            await viewModel.renameMeeting(to: newTitle)
                            if let idx = appState.meetings.firstIndex(where: { $0.id == meeting.id }) {
                                appState.meetings[idx].title = newTitle
                            }
                        }
                    },
                    onCopy: { viewModel.copyTranscript() },
                    onExport: { viewModel.exportMarkdown() },
                    onReprocess: { suppressEcho in
                        Task {
                            let outcome = await appState.reprocessMeeting(
                                meeting.id,
                                suppressEcho: suppressEcho
                            )
                            // A failure that kept the old transcript looks like a success otherwise.
                            if !outcome.ok { reprocessFailure = outcome.message }
                        }
                    },
                    onDateChange: { newDate in
                        Task { await viewModel.updateStartTime(newDate) }
                    },
                    onEditAudio: { showSplitTrimSheet = true },
                    viewModel: viewModel,
                    onUndoSplit: {
                        Task { await appState.undoSplit(meeting.id) }
                    },
                    onUndoTrim: {
                        Task { await appState.undoTrim(meeting.id) }
                    },
                    onUndoMerge: {
                        Task { await appState.undoMerge(meeting.id) }
                    }
                )
                .alert("Reprocess Failed", isPresented: Binding(
                    get: { reprocessFailure != nil }, set: { if !$0 { reprocessFailure = nil } }
                )) {
                    Button("OK") {}
                } message: {
                    Text(reprocessFailure ?? "")
                }
            }

            Divider()

            // Player bar: always reserve space once we know duration (from DB).
            // Falls back to meeting.durationSeconds while audio engine is still warming up — prevents layout shift.
            let playerDuration: TimeInterval = viewModel.playback.duration > 0
                ? viewModel.playback.duration
                : (viewModel.meeting?.durationSeconds ?? 0)
            if playerDuration > 0 {
                PlayerBarView(
                    isPlaying: viewModel.playback.isPlaying,
                    currentTime: viewModel.playback.currentTime,
                    duration: playerDuration,
                    activeTrack: viewModel.playback.activeTrack,
                    hasSystemAudio: viewModel.playback.hasSystemAudio,
                    playbackRate: viewModel.playback.playbackRate,
                    peaks: viewModel.waveformPeaks,
                    hueSpans: playerHueSpans,
                    onPlayPause: { viewModel.playback.togglePlayPause() },
                    onSeek: { time in viewModel.playback.seek(to: time) },
                    excludedZones: viewModel.excludedZones.map { (start: $0.start, end: $0.end) },
                    onTrackChange: { track in viewModel.playback.setTrack(track) },
                    onRateChange: { rate in viewModel.playback.setRate(rate) }
                )
                Divider()
            }

            // Filters bar
            HStack(spacing: VedivoxSpace.l) {
                Button {
                    editMode.toggle()
                } label: {
                    HStack(spacing: VedivoxSpace.xs) {
                        Image(systemName: editMode ? "square.and.pencil.circle.fill" : "square.and.pencil")
                            .frame(width: 18, height: 18)
                        Text("Edit speakers")
                            .vedivoxFont(.caption)
                            .fixedSize()
                    }
                    .foregroundStyle(editMode ? Color.Vedivox.accentText : Color.Vedivox.fgSecondary)
                }
                .buttonStyle(.plain)
                .help(editMode ? "Exit edit mode" : "Select segments to reassign their speaker or hide them")

                if !viewModel.uniqueSpeakerLabels.isEmpty {
                    Text("Speaker:")
                        .vedivoxFont(.caption)
                        .fixedSize()
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                    VedivoxPicker(
                        selection: $viewModel.speakerFilter,
                        options: viewModel.speakerFilterOptions
                    )
                    .fixedSize()
                }

                // one track's lines, and the whole mic track out of the transcript and back.
                if viewModel.hasBothTracks {
                    TrackSwitcher(
                        selected: viewModel.trackFilter,
                        label: { $0 == .mix ? "All" : $0.rawValue },
                        help: { $0 == .mix ? "Lines of both tracks" : "\($0.rawValue) lines only" },
                        choose: { viewModel.trackFilter = $0 }
                    )
                    .accessibilityIdentifier("transcript.trackFilter")
                    if viewModel.trackFilter == .mic {
                        Button(viewModel.micTrackExcluded ? "Restore mic track" : "Exclude mic track") {
                            Task { await viewModel.setMicTrackExcluded(!viewModel.micTrackExcluded) }
                        }
                        .buttonStyle(.vedivoxGhost)
                        .help(viewModel.micTrackExcluded
                            ? "Bring the mic lines back into the transcript"
                            : "Keep the whole mic track out of the transcript; the system track stays")
                        .accessibilityIdentifier("transcript.micTrackExclusion")
                    }
                }

                // Unnamed voices of this meeting that sound like a known
                // person: one click to the Listen section, filtered here.
                if viewModel.voicesToCheck > 0 {
                    Button("\(viewModel.voicesToCheck) voice\(viewModel.voicesToCheck == 1 ? "" : "s") to check") {
                        appState.openListen(meetingId: viewModel.meeting?.id)
                    }
                    .buttonStyle(.vedivoxGhost)
                    .help("Open the Listen section for this meeting")
                    .accessibilityIdentifier("transcript.voicesToCheck")
                }

                Spacer()

                HStack(spacing: VedivoxSpace.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                    TextField("Search transcript", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .vedivoxFont(.row)
                        .frame(width: 180)
                        // Esc clears the query, the next one leaves the field (#6).
                        .onKeyPress(.escape) {
                            if viewModel.searchText.isEmpty { focus.takeDetail() } else { viewModel.searchText = "" }
                            return .handled
                        }
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.Vedivox.fgSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, VedivoxSpace.m)
                .padding(.vertical, VedivoxSpace.s)
                .background(Color.Vedivox.bgInput, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
                .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.s).strokeBorder(Color.Vedivox.lineSoft))
            }
            .padding(.horizontal)
            .padding(.vertical, VedivoxSpace.xs)

            // Selection action bar
            if !viewModel.selectedSegmentIds.isEmpty {
                SelectionActionBar(
                    selectedCount: viewModel.selectedSegmentIds.count,
                    meSpeaker: viewModel.meSpeaker,
                    onReassign: { speakerId, speakerName in
                        Task { await viewModel.reassignSelectedSegments(speakerId: speakerId, speakerName: speakerName) }
                    },
                    onReassignNew: { name in
                        Task { await viewModel.reassignSelectedToNewSpeaker(name: name) }
                    },
                    onMarkAsMe: {
                        Task { await viewModel.markSelectedAsMe() }
                    },
                    onExclude: {
                        Task { await viewModel.excludeSelectedSegments() }
                    },
                    onInclude: {
                        Task { await viewModel.includeSelectedSegments() }
                    },
                    onClear: { viewModel.clearSelection() }
                )
                Divider()
            }

            // Вопрос после обработки: чужой голос на микрофоне — участник или фон?
            if viewModel.showForeignPrompt {
                ForeignMicPromptBanner(
                    count: viewModel.foreignMicSegments.count,
                    alreadyHidden: viewModel.hiddenForeignCount > 0,
                    onExclude: { Task { await viewModel.hideForeignVoices() } },
                    onKeep: { Task { await viewModel.keepForeignVoices() } }
                )
                Divider()
            } else if viewModel.showHiddenForeignNotice {
                // Отчёт, не вопрос: в этом режиме вопрос не задаётся по
                // определению, но молчаливо скрытое обязано быть видно.
                HiddenForeignNoticeRow(
                    count: viewModel.hiddenForeignCount,
                    onRestore: { Task { await viewModel.keepForeignVoices() } }
                )
                Divider()
            }

            // Edit mode bar (split/trim)
            if let meeting = viewModel.meeting, viewModel.editMode != nil {
                EditModeBar(
                    viewModel: viewModel,
                    onSplit: { splitTime in
                        Task { await appState.splitMeeting(meeting.id, atTime: splitTime) }
                    },
                    onTrim: { from, to in
                        Task { await appState.trimMeeting(meeting.id, keepFrom: from, keepTo: to) }
                    }
                )
            }

            // Segments
            TranscriptSegmentsList(viewModel: viewModel, editMode: editMode)
        }
        .task(id: meetingId) {
            let taskEnter = CFAbsoluteTimeGetCurrent()
            // -1: not opened by a click on this meeting. Used once, so a later
            // switch by Listen or a link is not measured from it.
            let clickAt = appState.lastMeetingClick.flatMap { $0.id == meetingId ? $0.at : nil }
            appState.lastMeetingClick = nil
            let clickToTaskMs = clickAt.map { Int((taskEnter - $0) * 1000) } ?? -1
            Log.info("[Perf][MeetingSwitch] \(meetingId) click→task=\(clickToTaskMs)ms")

            viewModel.speakerFilter = nil
            viewModel.trackFilter = .mix
            viewModel.searchText = ""
            viewModel.clearSelection()
            viewModel.exitEditMode()
            // The player still holds the previous meeting's audio here.
            rememberPlaybackPosition()
            // A link to a moment wins over the remembered position.
            let resumeAt = appState.pendingSeekTime == nil
                ? appState.meetingPlaybackPositions[meetingId] ?? 0 : 0
            await viewModel.load(meetingId: meetingId, resumeAt: resumeAt)

            let afterLoad = CFAbsoluteTimeGetCurrent()
            let taskToLoadEndMs = Int((afterLoad - taskEnter) * 1000)
            let clickToLoadEndMs = clickAt.map { Int((afterLoad - $0) * 1000) } ?? -1
            Log.info("[Perf][MeetingSwitch] \(meetingId) task→loadend=\(taskToLoadEndMs)ms click→loadend=\(clickToLoadEndMs)ms")

            await Task.yield()
            let afterYield = CFAbsoluteTimeGetCurrent()
            Log.info("[Perf][MeetingSwitch] \(meetingId) loadend→yield=\(Int((afterYield - afterLoad) * 1000))ms")

            if let seekTime = appState.pendingSeekTime {
                appState.pendingSeekTime = nil
                viewModel.seekAndPlay(to: seekTime)
            }
        }
        .onChange(of: appState.pendingSeekTime) { (_: Double?, newSeekTime: Double?) in
            guard let seekTime = newSeekTime else { return }
            // Consume seek only when this meeting is already loaded (deep link
            // to the same meeting). A link to another meeting reaches this view
            // before the switch; the `.task` tail consumes it after the load,
            // otherwise the link took two clicks.
            guard viewModel.meeting?.id == meetingId else { return }
            appState.pendingSeekTime = nil
            viewModel.seekAndPlay(to: seekTime)
        }
        .onChange(of: appState.transcriptVersion) {
            Task { await viewModel.load(meetingId: meetingId) }
        }
        .onDisappear {
            rememberPlaybackPosition()
            // The player dies with this view, but its 10 Hz timer and its
            // "playing" claim on Now Playing did not: one more timer per visit,
            // and dictation paused Vedivox instead of the music.
            viewModel.playback.stop()
        }
    }

    private func rememberPlaybackPosition() {
        guard let position = viewModel.leavingPosition else { return }
        appState.meetingPlaybackPositions[position.meetingId] = position.time
    }
}

// MARK: - Exclusion Banners

/// «На микрофоне N реплик чужого голоса — участник или фон?» The system already
/// knows the voice is not the owner's — named or not; only the intent needs a
/// human, so ask once per meeting.
private struct ForeignMicPromptBanner: View {
    let count: Int
    /// The default hid them before asking — say so, or «hide» reads as a no-op.
    let alreadyHidden: Bool
    let onExclude: () -> Void
    let onKeep: () -> Void

    var body: some View {
        HStack(spacing: VedivoxSpace.m) {
            Image(systemName: "person.fill.questionmark")
                .foregroundStyle(Color.Vedivox.accentText)
            Text(alreadyHidden
                 ? "\(count) foreign-voice segment\(count == 1 ? "" : "s") on the mic \(count == 1 ? "is" : "are") hidden — participant or background?"
                 : "\(count) foreign-voice segment\(count == 1 ? "" : "s") on the mic — participant or background?")
                .vedivoxFont(.row)
            Button(alreadyHidden ? "Background — keep hidden" : "Background — hide") { onExclude() }
                .buttonStyle(.vedivoxLink)
            Button(alreadyHidden ? "Participant — bring back" : "Participant — keep") { onKeep() }
                .buttonStyle(.vedivoxLink)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, VedivoxSpace.s)
        .background(Color.Vedivox.bgSidebar)
    }
}

/// Silently hidden speech still has to be visible as a fact: how much went, and
/// one click to get it back. A report, not a question — in this mode the
/// question is not asked by definition.
private struct HiddenForeignNoticeRow: View {
    let count: Int
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: VedivoxSpace.m) {
            Image(systemName: "eye.slash")
                .foregroundStyle(Color.Vedivox.fgSecondary)
            Text("\(count) foreign-voice segment\(count == 1 ? "" : "s") on the mic hidden")
                .vedivoxFont(.row)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            Button("Bring back") { onRestore() }
                .buttonStyle(.vedivoxLink)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, VedivoxSpace.s)
        .background(Color.Vedivox.bgSidebar)
    }
}

private func formatMinutes(_ seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    if mins > 0 { return "\(mins)m \(secs)s" }
    return "\(secs)s"
}

// MARK: - Header

private struct TranscriptHeaderView: View {
    let meeting: Meeting
    /// The window's focus, so finishing a rename hands the keyboard back to
    /// the detail region instead of leaving it nowhere.
    var focus: FocusState<MainFocus?>.Binding
    var onRename: (String) -> Void
    let onCopy: () -> Void
    let onExport: () -> Void
    /// suppressEcho — the one processing-time knob left in the reprocess
    /// popover. Foreign voices are a display question now, answered in the
    /// banner and applied without reprocessing (решение 8).
    let onReprocess: (Bool?) -> Void
    let onDateChange: (Date) -> Void
    let onEditAudio: () -> Void
    @Bindable var viewModel: MeetingDetailViewModel
    let onUndoSplit: () -> Void
    let onUndoTrim: () -> Void
    let onUndoMerge: () -> Void

    @State private var editingTitle: String = ""
    @State private var isEditing = false
    @State private var isEditingDate = false
    @State private var showReprocessPopover = false
    /// When processing of the open meeting ended.
    @State private var finishedAt: Date?
    @State private var showUndoSplitConfirm = false
    @State private var showUndoTrimConfirm = false
    @State private var showUndoMergeConfirm = false
    @Environment(AppState.self) private var appState

    /// Recording or processing: the audio and transcript are incomplete, so
    /// every action that would act on them waits.
    private var isBusy: Bool { meeting.status.isInProgress }
    /// Transcribing or diarizing, not recording.
    private var isProcessing: Bool { isBusy && meeting.status != .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
            HStack {
                if isEditing {
                    // The framed `vedivoxField` is what makes edit mode visible: with
                    // `.plain` and the same font the field was indistinguishable
                    // from the title, so «Rename» looked like it did nothing.
                    TextField("Meeting title", text: $editingTitle)
                        .vedivoxFont(.title)
                        .vedivoxField()
                        .focused(focus, equals: .title)
                        .accessibilityIdentifier("meeting.titleField")
                        .onSubmit {
                            isEditing = false
                            if !editingTitle.isEmpty {
                                onRename(editingTitle)
                            }
                        }
                        .onExitCommand {
                            isEditing = false
                        }
                } else {
                    Text(meeting.title)
                        .vedivoxFont(.title)
                        .foregroundStyle(Color.Vedivox.fg)
                        // Truncates first when the column is narrow: the
                        // actions keep their size, the title gives way.
                        .lineLimit(1)
                        .layoutPriority(-1)
                        .accessibilityIdentifier("meeting.title")
                        .onTapGesture {
                            beginEditing()
                        }
                }

                if RevealButtonPlacement.chosen == .meetingHeader {
                    RevealInSidebarButton().buttonStyle(.vedivoxIcon)
                }

                Spacer()

                // Undo buttons (visible only when available)
                if viewModel.canUndoSplit {
                    Button {
                        showUndoSplitConfirm = true
                    } label: {
                        Label("Undo Split", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.vedivoxGhost)
                    .help("Undo the last split and merge meetings back")
                    .disabled(isBusy)
                    .alert("Undo Split", isPresented: $showUndoSplitConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Undo Split", role: .destructive) { onUndoSplit() }
                    } message: {
                        Text("The two meetings will be merged back into one. Speaker and text edits will be preserved.")
                    }
                }

                if viewModel.canUndoTrim {
                    Button {
                        showUndoTrimConfirm = true
                    } label: {
                        Label("Undo Trim", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.vedivoxGhost)
                    .help("Restore original audio and reprocess")
                    .disabled(isBusy)
                    .alert("Undo Trim", isPresented: $showUndoTrimConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Undo Trim", role: .destructive) { onUndoTrim() }
                    } message: {
                        Text("Original audio will be restored and the meeting will be reprocessed. Text and speaker edits will be lost.")
                    }
                }

                if viewModel.canUndoMerge {
                    Button {
                        showUndoMergeConfirm = true
                    } label: {
                        Label("Undo Merge", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.vedivoxGhost)
                    .help("Split back into two separate meetings")
                    .disabled(isBusy)
                    .alert("Undo Merge", isPresented: $showUndoMergeConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Undo Merge", role: .destructive) { onUndoMerge() }
                    } message: {
                        Text("The meeting will be split back into the original two meetings.")
                    }
                }

                // «Скрытое видимо как скрытое»: the counter lives with the other
                // actions instead of its own banner row. Present only when there
                // IS something hidden — an empty toggle would be noise.
                if viewModel.excludedCount > 0 {
                    Button {
                        viewModel.showExcluded.toggle()
                    } label: {
                        Label("\(viewModel.excludedCount)", systemImage: viewModel.showExcluded ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.vedivoxGhost)
                    .help(
                        "\(viewModel.excludedCount) segment\(viewModel.excludedCount == 1 ? "" : "s") "
                        + "(\(formatMinutes(viewModel.excludedDuration))) excluded from transcript — "
                        + (viewModel.showExcluded ? "hide" : "show")
                    )
                }

                // Split / trim modal. Inline per-segment mode is
                // still reachable via the transcript context menu.
                Button {
                    onEditAudio()
                } label: {
                    Label("Trim / Split", systemImage: "scissors")
                }
                .buttonStyle(.vedivoxGhost)
                .help("Split or trim this meeting")
                .disabled(isBusy)

                Button {
                    showReprocessPopover = true
                } label: {
                    // The button that started the run shows it going.
                    if isProcessing {
                        HStack(spacing: VedivoxSpace.xs) {
                            ProgressView().controlSize(.mini)
                            Text("Processing…")
                        }
                        .accessibilityIdentifier("meeting.processing")
                    } else {
                        Label("Reprocess", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.vedivoxGhost)
                .help(isProcessing ? "The meeting is being processed" : "Re-run transcription and diarization")
                .disabled(isBusy)
                .popover(isPresented: $showReprocessPopover) {
                    ReprocessPopoverContent(
                        onReprocess: { suppressEcho in
                            showReprocessPopover = false
                            onReprocess(suppressEcho)
                        }
                    )
                }

                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.vedivoxGhost)
                .help("Copy transcript to clipboard")
                .disabled(isBusy)

                Button {
                    onExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.vedivoxGhost)
                .help("Export transcript as Markdown")
                .disabled(isBusy)
            }

            // Own row under the title, one line: squeezed beside the actions
            // it wrapped one character per line at 1100 pt.
            HStack(spacing: VedivoxSpace.m) {
                if isEditingDate {
                    DatePicker("", selection: Binding(
                        get: { meeting.startTime },
                        set: { newDate in
                            onDateChange(newDate)
                            isEditingDate = false
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Label(meeting.startTime.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .onTapGesture { isEditingDate = true }
                }

                if let duration = meeting.durationSeconds {
                    Label(formatDuration(duration), systemImage: "clock")
                }

                // The old transcript stays on screen while a reprocess runs, so
                // without this nothing said it had ended; the run
                // itself shows on the Reprocess button.
                if !isBusy, let finishedAt {
                    if meeting.status == .error {
                        Label("Processing failed", systemImage: "exclamationmark.triangle")
                    } else {
                        Label("Processing finished \(finishedAt.formatted(date: .omitted, time: .shortened))",
                              systemImage: "checkmark.circle")
                    }
                }
            }
            .vedivoxFont(.caption)
            .foregroundStyle(Color.Vedivox.fgSecondary)
            .lineLimit(1)
        }
        .padding()
        // Processing of this meeting ended while it was open: the mark stays
        // until another meeting is opened.
        .onChange(of: [meeting.id, meeting.status.rawValue]) { old, new in
            let wasProcessing = old[1] != MeetingStatus.recording.rawValue
                && MeetingStatus(rawValue: old[1])?.isInProgress == true
            let ended = old[0] == new[0] && wasProcessing && !meeting.status.isInProgress
            if ended { finishedAt = .now } else if old[0] != new[0] { finishedAt = nil }
        }
        .onChange(of: meeting.id) { _, _ in
            isEditing = false
            isEditingDate = false
            consumeRenameRequest()
        }
        // Sidebar context-menu «Переименовать». The request can
        // arrive before this header exists (meeting wasn't open yet), so it is
        // also consumed on appear and on meeting switch.
        .onChange(of: appState.renameRequestMeetingId) { _, _ in
            consumeRenameRequest()
        }
        .onAppear { consumeRenameRequest() }
        // Leaving edit mode (Return, Esc) removes the focused field; hand the
        // keyboard back to the region so the player keys keep working.
        .onChange(of: isEditing) { _, editing in
            if !editing { focus.takeDetail() }
        }
    }

    private func beginEditing() {
        editingTitle = meeting.title
        isEditing = true
        // Focus goes through AppKit — see `focusTitleField`. Started here, not
        // in the field's `onAppear`: renaming another meeting while one is
        // being edited flips `isEditing` off and on in one update, the field is
        // never re-created, and `onAppear` does not fire. Held for half a
        // second: the meeting switch and the menu that asked for the rename can
        // take first responder back after the field got it.
        Task { @MainActor in
            for tick in 0 ..< 10 {
                try? await Task.sleep(for: .milliseconds(50))
                if Self.focusTitleField() == .refocused, tick > 0 {
                    Log.debug("Title field focus taken back (tick \(tick))")
                }
            }
        }
    }

    private func consumeRenameRequest() {
        guard appState.renameRequestMeetingId == meeting.id else { return }
        beginEditing()
        appState.renameRequestMeetingId = nil
    }

    /// Makes the title field first responder through AppKit. SwiftUI focus
    /// cannot reach it: the detail region is one `.focusable()` stop, and a
    /// programmatic `.title` focus inside it resolves to nil (probe:
    /// ten attempts over 0.5 s, all nil). A click works because it goes
    /// straight to AppKit; this does the same for «Rename» from the menu.
    /// Found by its placeholder — keep it in sync with the TextField above.
    private enum TitleFocus { case alreadyFocused, refocused, unavailable }

    @MainActor
    private static func focusTitleField() -> TitleFocus {
        guard let window = NSApp.keyWindow, let root = window.contentView else { return .unavailable }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, field.placeholderString == "Meeting title" {
                return field
            }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        guard let field = find(root) else { return .unavailable }
        // Already editing: the field editor is first responder on its behalf.
        // Re-focusing would select all and throw away what is being typed.
        if let editor = window.firstResponder as? NSTextView, editor.delegate === field {
            return .alreadyFocused
        }
        return window.makeFirstResponder(field) ? .refocused : .unavailable
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m \(secs)s"
    }
}

// MARK: - Edit Mode Bar (Split / Trim)

/// Popover content for reprocess. Enrollment happens automatically from the
/// speaker pool (pool hygiene lives in the pipeline) — the only
/// user-facing knob is echo suppression for speakers-without-headphones calls.
/// Stage checkboxes from the design mock need partial reprocess in the
/// pipeline, which doesn't exist yet (deliberately out of scope).
private struct ReprocessPopoverContent: View {
    let onReprocess: (Bool?) -> Void

    /// nil = автодетект по корреляции огибающих.
    private enum EchoMode: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case on = "On"
        case off = "Off"
        var id: String { rawValue }
        var value: Bool? {
            switch self {
            case .auto: nil
            case .on: true
            case .off: false
            }
        }
    }

    @State private var echoMode: EchoMode = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.l) {
            Text("Reprocess Meeting")
                .vedivoxFont(.bodyStrong)
                .foregroundStyle(Color.Vedivox.fg)
            Text("Transcription and diarization run again; the current transcript is replaced. Known speakers are recognized automatically.")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)

            Divider()

            LabeledContent("Speaker echo") {
                Picker("", selection: $echoMode) {
                    ForEach(EchoMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .vedivoxFont(.row)
            .help("Mutes the mic track while system audio is playing — for calls without headphones. Auto detects speakers by channel correlation.")

            HStack {
                Spacer()
                Button("Run") {
                    onReprocess(echoMode.value)
                }
                .buttonStyle(.vedivoxProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

private struct EditModeBar: View {
    @Bindable var viewModel: MeetingDetailViewModel
    let onSplit: (Double) -> Void
    let onTrim: (Double, Double) -> Void

    @State private var showSplitConfirm = false
    @State private var showTrimConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: VedivoxSpace.l) {
                Picker("", selection: Binding(
                    get: { viewModel.editMode ?? .split },
                    set: { viewModel.enterEditMode($0) }
                )) {
                    Text("Split").tag(MeetingDetailViewModel.EditMode.split)
                    Text("Trim").tag(MeetingDetailViewModel.EditMode.trim)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                Divider().frame(height: 20)

                // Content depends on mode
                if viewModel.editMode == .split {
                    splitContent
                } else {
                    trimContent
                }

                Spacer()

                Button {
                    viewModel.exitEditMode()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }
                .buttonStyle(.plain)
                .help("Cancel editing")
            }
            .padding(.horizontal)
            .padding(.vertical, VedivoxSpace.m)
            .background(Color.Vedivox.bgHover)

            Divider()
        }
        .alert("Split Meeting", isPresented: $showSplitConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Split") {
                if let time = viewModel.splitTime {
                    viewModel.exitEditMode()
                    onSplit(time)
                }
            }
        } message: {
            if let p = viewModel.splitPreview {
                Text("The meeting will be split into two parts:\nPart 1: \(formatTime(0)) – \(formatTime(p.splitTime)) (\(p.part1Segments) segments)\nPart 2: \(formatTime(p.splitTime)) – \(formatTime(p.duration)) (\(p.part2Segments) segments)")
            }
        }
        .alert("Trim Meeting", isPresented: $showTrimConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Trim") {
                if let from = viewModel.trimFromTime, let to = viewModel.trimToTime {
                    viewModel.exitEditMode()
                    onTrim(from, to)
                }
            }
        } message: {
            if let p = viewModel.trimPreview {
                Text("Keep \(formatTime(p.from)) – \(formatTime(p.to)) (\(p.keepSegments) segments). \(p.removeSegments) segments will be removed.")
            }
        }
    }

    @ViewBuilder
    private var splitContent: some View {
        if let preview = viewModel.splitPreview {
            HStack(spacing: VedivoxSpace.m) {
                Circle().fill(Color.Vedivox.success).frame(width: VedivoxSize.dot, height: VedivoxSize.dot)
                Text("\(formatTime(0))–\(formatTime(preview.splitTime))")
                Text("(\(preview.part1Segments))").foregroundStyle(Color.Vedivox.fgSecondary)

                Circle().fill(Color.Vedivox.warning).frame(width: VedivoxSize.dot, height: VedivoxSize.dot)
                Text("\(formatTime(preview.splitTime))–\(formatTime(preview.duration))")
                Text("(\(preview.part2Segments))").foregroundStyle(Color.Vedivox.fgSecondary)

                Button("Split") {
                    showSplitConfirm = true
                }
                .buttonStyle(.vedivoxProminent)
                .disabled(preview.part1Segments == 0 || preview.part2Segments == 0)
            }
            .vedivoxFont(.row)
        } else {
            Text("Click a segment to set the split point")
                .vedivoxFont(.row)
                .foregroundStyle(Color.Vedivox.fgSecondary)
        }
    }

    @ViewBuilder
    private var trimContent: some View {
        if let preview = viewModel.trimPreview {
            HStack(spacing: VedivoxSpace.m) {
                Text("Keep \(formatTime(preview.from))–\(formatTime(preview.to))")
                Text("(\(preview.keepSegments) seg)").foregroundStyle(Color.Vedivox.fgSecondary)
                Text("remove \(preview.removeSegments)").foregroundStyle(Color.Vedivox.danger)

                Button("Trim") {
                    showTrimConfirm = true
                }
                .buttonStyle(.vedivoxProminent)
                .disabled(preview.keepSegments == 0)
            }
            .vedivoxFont(.row)
        } else if viewModel.trimFromTime != nil {
            HStack(spacing: VedivoxSpace.m) {
                Text("From: \(formatTime(viewModel.trimFromTime!))")
                Text("— click another segment for end point")
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
            .vedivoxFont(.row)
        } else {
            Text("Click a segment for start, then another for end")
                .vedivoxFont(.row)
                .foregroundStyle(Color.Vedivox.fgSecondary)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", mins)):\(String(format: "%02d", secs))"
        }
        return "\(mins):\(String(format: "%02d", secs))"
    }
}

// MARK: - Segments List

private struct TranscriptSegmentsList: View {
    @Environment(AppState.self) private var appState
    @Environment(\.undoManager) private var undoManager
    @Bindable var viewModel: MeetingDetailViewModel
    let editMode: Bool
    /// The anchor of a Shift-click range, by segment id. It was an index into
    /// the filtered list, which shrinks under it (an Exclude, a search, a
    /// speaker filter, another meeting): the next Shift-click indexed past the
    /// end and crashed.
    @State private var lastSelectedId: Int64?
    /// Delayed spinner: only appears if loading takes >250 ms and segments are empty.
    /// Prevents flash-of-loading-state on fast meeting switches (previous content stays visible).
    @State private var showDelayedSpinner = false

    var body: some View {
        Group {
            if !viewModel.segments.isEmpty {
                segmentsList
            } else if showDelayedSpinner {
                ProgressView("Loading transcript...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.isLoading {
                emptyState
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // ContentUnavailableView only takes its own height; without this the
        // column centred vertically and the header slid to mid-window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: viewModel.isLoading) {
            if viewModel.isLoading {
                try? await Task.sleep(for: .milliseconds(250))
                if viewModel.isLoading {
                    showDelayedSpinner = true
                }
            } else {
                showDelayedSpinner = false
            }
        }
    }

    /// Honest per-status empty state: recording is not transcribing,
    /// and the model-compile caption belongs to ModelLoadingBanner, not here.
    @ViewBuilder
    private var emptyState: some View {
        switch viewModel.meeting?.status {
        case .recording:
            if let id = viewModel.meeting?.id {
                LiveTranscriptPane(meetingId: id)
            }
        case .transcribing, .diarizing:
            VStack(spacing: VedivoxSpace.l) {
                ProgressView()
                    .controlSize(.large)
                Text(processingStageLabel)
                    .vedivoxFont(.bodyStrong)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsAttention:
            ContentUnavailableView(
                "Track Lost",
                systemImage: "exclamationmark.circle",
                description: Text("A track that sounded produced no transcript. Reprocess the meeting or check its audio.")
            )
        case .error:
            ContentUnavailableView {
                Label("Processing Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failureDescription)
            } actions: {
                if let id = viewModel.meeting?.id {
                    Button("Reprocess") { Task { await appState.reprocessMeeting(id) } }
                }
            }
        case .done:
            // Silence-only segments are not saved (#6), so a finished
            // meeting can be empty without anything having gone wrong.
            ContentUnavailableView(
                "No Speech",
                systemImage: "waveform.slash",
                description: Text("Nothing was recognized in this recording.")
            )
        default:
            ContentUnavailableView(
                "No Transcript",
                systemImage: "text.alignleft",
                description: Text("This meeting hasn't been transcribed yet.")
            )
        }
    }

    /// The reason when this run knows it: the processing error, or
    /// models that did not load; otherwise the log.
    private var failureDescription: String {
        let log = "Details are in the log (Settings → Storage → Logs)."
        if let id = viewModel.meeting?.id, let reason = appState.processingFailureReasons[id] {
            return "Vedivox could not transcribe this meeting: \(reason). \(log)"
        }
        if let modelError = appState.modelLoadError {
            return "The speech models are not loaded (\(modelError)). Once they load, reprocess the meeting. \(log)"
        }
        return "Vedivox could not transcribe this meeting. \(log)"
    }

    private var processingStageLabel: String {
        switch viewModel.meeting?.status {
        case .diarizing: "Identifying speakers..."
        default: "Transcribing..."
        }
    }

    /// Maps segment id → its run's anchor id (= first segment's id).
    /// Used in Smart mode so scrollTo(activeSegmentId) lands on the run that contains it,
    /// not on a non-registered mid-run segment id.
    private var runAnchorMap: [Int64: Int64] {
        guard !editMode else { return [:] }
        var map: [Int64: Int64] = [:]
        for run in SegmentGrouping.groupRuns(viewModel.filteredSegments) {
            for seg in run.segments {
                if let sid = seg.id {
                    map[sid] = run.id
                }
            }
        }
        return map
    }

    private var segmentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: editMode ? 8 : 16) {
                    if editMode {
                        ForEach(Array(viewModel.filteredSegments.enumerated()), id: \.element.id) { index, segment in
                            segmentRow(for: segment, at: index)
                                .id(segment.id)
                        }
                    } else {
                        ForEach(TranscriptRow.merge(
                            SegmentGrouping.groupRuns(viewModel.filteredSegments),
                            dictations: viewModel.dictations
                        )) { row in
                          switch row {
                          case .dictation(let mark):
                            DictationPlaque(mark: mark) { viewModel.seekAndPlay(to: mark.startTime) }
                                .id(row.id)
                          case .run(let run):
                            SmartRunRow(
                                run: run,
                                activeSegmentId: viewModel.activeSegmentId,
                                searchText: viewModel.searchText,
                                onSeek: { viewModel.seekAndPlay(to: $0) },
                                onRenameSpeaker: { name, speakerId in
                                    guard let anchor = run.segments.first else { return }
                                    Task {
                                        await offerUndo(await viewModel.renameSpeaker(
                                            segment: anchor, newName: name, existingSpeakerId: speakerId, run: run.segments
                                        ), named: "Rename Speaker")
                                    }
                                },
                                onMarkAsMe: {
                                    guard let anchor = run.segments.first else { return }
                                    Task {
                                        await offerUndo(
                                            await viewModel.markSpeakerAsMe(segment: anchor, run: run.segments),
                                            named: "Mark as Me"
                                        )
                                    }
                                },
                                onSplitHere: {
                                    viewModel.enterEditMode(.split)
                                    viewModel.splitTime = run.startTime
                                },
                                onExclude: {
                                    let targets = run.segments
                                    Task { await viewModel.excludeSegments(targets) }
                                },
                                onInclude: {
                                    let targets = run.segments
                                    Task { await viewModel.includeSegments(targets) }
                                }
                            )
                            .opacity(run.isExcluded ? 0.4 : 1.0)
                            .id(run.id)
                          }
                        }
                    }
                }
                .padding()
                .background(
                    // macOS 14-compatible scroll tracking: replaces
                    // .onScrollGeometryChange (macOS 15+). Reads the content's
                    // offset in the ScrollView's coordinate space and reacts on
                    // change — same "manual scroll disables follow" behavior.
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.frame(in: .named("transcriptScroll")).minY) { oldVal, newVal in
                                if viewModel.isProgrammaticScroll { return }
                                // Любое намеренное движение колесом/тачпадом выключает follow,
                                // чтобы playback не возвращал скролл на активный при следующей смене сегмента.
                                // Порог 30px фильтрует только мелкие SwiftUI-шумы layout'а.
                                if viewModel.playback.isPlaying, abs(newVal - oldVal) > 30 {
                                    viewModel.disableAutoScroll()
                                }
                            }
                    }
                )
            }
            .coordinateSpace(.named("transcriptScroll"))
            .onKeyPress(.escape) {
                if viewModel.editMode != nil {
                    viewModel.exitEditMode()
                    return .handled
                }
                if !viewModel.selectedSegmentIds.isEmpty {
                    viewModel.clearSelection()
                    lastSelectedId = nil
                    return .handled
                }
                return .ignored
            }
            .onChange(of: viewModel.activeSegmentId) { _, newId in
                if viewModel.autoScrollEnabled, let id = newId {
                    let target = editMode ? id : (runAnchorMap[id] ?? id)
                    viewModel.isProgrammaticScroll = true
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    // Reset after animation completes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        viewModel.isProgrammaticScroll = false
                    }
                }
            }
            .onChange(of: editMode) { _, _ in
                // Keep focus on the currently-playing segment when toggling modes.
                // Instant scroll (no animation) so the user doesn't see the view pan
                // from the old layout's scroll offset to the new one — it just blinks
                // into place centered on the active segment.
                guard let id = viewModel.activeSegmentId else { return }
                viewModel.autoScrollEnabled = true
                DispatchQueue.main.async {
                    let target = editMode ? id : (runAnchorMap[id] ?? id)
                    viewModel.isProgrammaticScroll = true
                    proxy.scrollTo(target, anchor: .center)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        viewModel.isProgrammaticScroll = false
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !viewModel.autoScrollEnabled, viewModel.activeSegmentId != nil {
                    Button {
                        viewModel.autoScrollEnabled = true
                        if let id = viewModel.activeSegmentId {
                            let target = editMode ? id : (runAnchorMap[id] ?? id)
                            viewModel.isProgrammaticScroll = true
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                viewModel.isProgrammaticScroll = false
                            }
                        }
                    } label: {
                        Label("Follow", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.vedivoxFloating)
                    .padding(.bottom, VedivoxSpace.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.22), value: viewModel.autoScrollEnabled)
                }
            }
        }
    }

    /// Puts a speaker change on Edit → Undo.
    private func offerUndo(_ undo: SpeakerUndo?, named name: String) async {
        guard let undo else { return }
        await undoManager?.registerSpeakerUndo(undo, named: name) { failure in
            if let failure { appState.speakerUndoFailure = failure }
            appState.transcriptVersion += 1
        }
    }

    private func segmentRow(for segment: TranscriptSegment, at index: Int) -> some View {
        let isSelected = segment.id.map { viewModel.selectedSegmentIds.contains($0) } ?? false
        let inEditMode = viewModel.editMode != nil
        let isPart2 = viewModel.isSegmentInPart2(segment)
        let isTrimmed = viewModel.isSegmentTrimmed(segment)
        let isSplitPoint = viewModel.editMode == .split && viewModel.splitTime == segment.startTime

        return VStack(spacing: 0) {
            TranscriptSegmentRow(
                segment: segment,
                isActive: !inEditMode && segment.id == viewModel.activeSegmentId,
                onTextUpdate: { newText in
                    if let id = segment.id {
                        Task {
                            await viewModel.updateSegmentText(segmentId: id, newText: newText)
                        }
                    }
                },
                onTimecodeTap: { time in
                    if inEditMode {
                        viewModel.handleEditModeTap(segment: segment)
                    } else {
                        viewModel.seekAndPlay(to: time)
                    }
                },
                onEditStart: {
                    viewModel.pauseForEditing()
                },
                searchText: viewModel.searchText,
                onSpeakerRename: { newName, speakerId in
                    Task {
                        await offerUndo(await viewModel.renameSpeaker(
                            segment: segment,
                            newName: newName,
                            existingSpeakerId: speakerId
                        ), named: "Rename Speaker")
                    }
                },
                onSpeakerReassign: segment.id.map { segmentId in
                    { speakerId, speakerName in
                        Task {
                            await viewModel.reassignSegmentSpeaker(
                                segmentId: segmentId,
                                speakerId: speakerId,
                                speakerName: speakerName
                            )
                        }
                    }
                },
                onSpeakerReassignNew: segment.id.map { segmentId in
                    { name in
                        Task {
                            await viewModel.reassignSegmentToNewSpeaker(
                                segmentId: segmentId,
                                name: name
                            )
                        }
                    }
                },
                onMarkAsMe: viewModel.meSpeaker != nil && segment.speakerId != viewModel.meSpeaker?.id ? {
                    Task {
                        await offerUndo(await viewModel.markSpeakerAsMe(segment: segment), named: "Mark as Me")
                    }
                } : nil,
                isSelected: isSelected,
                onSelect: segment.id.map { segmentId in
                    { (flags: NSEvent.ModifierFlags) in
                        handleSegmentSelect(segmentId: segmentId, index: index, flags: flags)
                    }
                }
            )
            .opacity(isTrimmed ? 0.35 : isPart2 ? 0.55 : segment.isExcluded ? 0.4 : 1.0)
            .background(
                isSplitPoint
                    ? RoundedRectangle(cornerRadius: VedivoxRadius.s).fill(Color.Vedivox.dangerSoft)
                    : nil
            )
            .overlay {
                if inEditMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.handleEditModeTap(segment: segment)
                        }
                }
            }
        }
    }

    private func handleSegmentSelect(segmentId: Int64, index: Int, flags: NSEvent.ModifierFlags) {
        let segments = viewModel.filteredSegments

        if flags.contains(.shift), let lastSelectedId {
            guard let lastIdx = segments.firstIndex(where: { $0.id == lastSelectedId }),
                  segments.indices.contains(index) else { return }
            let range = min(lastIdx, index) ... max(lastIdx, index)
            for i in range {
                if let id = segments[i].id {
                    viewModel.selectedSegmentIds.insert(id)
                }
            }
        } else if flags.contains(.command) {
            if viewModel.selectedSegmentIds.contains(segmentId) {
                viewModel.selectedSegmentIds.remove(segmentId)
            } else {
                viewModel.selectedSegmentIds.insert(segmentId)
            }
            lastSelectedId = segmentId
        }
    }
}

/// A dictation made while the meeting recorded. Its stretch of the
/// mic track is out of the transcript; this row says why and shows what was
/// dictated. Click plays the moment.
private struct DictationPlaque: View {
    let mark: MeetingMark
    let onSeek: () -> Void

    var body: some View {
        Button(action: onSeek) {
            HStack(alignment: .firstTextBaseline, spacing: VedivoxSpace.m) {
                Image(systemName: "mic.badge.xmark")
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                    Text("Dictation · \(TranscriptSegment.formatTime(mark.startTime))")
                        .vedivoxFont(.overline)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                    if let text = mark.text {
                        Text(text)
                            .vedivoxFont(.row)
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VedivoxSpace.l)
            .padding(.vertical, VedivoxSpace.s)
            .background(Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dictated while recording — kept out of the transcript")
    }
}
