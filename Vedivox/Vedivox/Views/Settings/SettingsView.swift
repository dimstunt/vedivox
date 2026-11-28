import AppKit
import AudioToolbox
import AVFoundation
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Settings window: section navigator on the left, content on the right —
/// per the Claude Design bundle (`settings-view.jsx`),
struct SettingsView: View {
    /// Sections only, never settings keys: moving a row between sections keeps
    /// its UserDefaults key.
    enum Section: String, CaseIterable, Identifiable {
        case general, recording, meetings, transcript, dictation, myVoice, shortcuts
        case storage, privacy, about

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: "General"
            case .recording: "Recording"
            case .meetings: "Meetings"
            case .transcript: "Transcript"
            case .dictation: "Dictation"
            case .myVoice: "My Voice"
            case .shortcuts: "Shortcuts"
            case .storage: "Storage"
            case .privacy: "Privacy & Permissions"
            case .about: "About"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .recording: "mic"
            case .meetings: "video"
            case .transcript: "waveform"
            case .dictation: "text.cursor"
            case .myVoice: "person.wave.2"
            case .shortcuts: "keyboard"
            case .storage: "internaldrive"
            case .privacy: "hand.raised"
            case .about: "info.circle"
            }
        }
    }

    @Environment(AppState.self) private var appState
    /// Kept in AppState so a return to Settings reopens the last section
    /// (screen-state-memory).
    private var section: Section {
        get { appState.settingsSection }
        nonmutating set { appState.settingsSection = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            navigator
            Divider().background(Color.Vedivox.lineSoft)
            ScrollView {
                Group {
                    switch section {
                    case .general: GeneralSection()
                    case .recording: RecordingSection()
                    case .meetings: MeetingsSection()
                    case .transcript: TranscriptSection()
                    case .dictation: DictationSection()
                    case .myVoice: MyVoiceSection()
                    case .shortcuts: ShortcutsSection()
                    case .storage: StorageSection()
                    case .privacy: PrivacySection()
                    case .about: AboutSection()
                    }
                }
                .padding(VedivoxSpace.xxl)
                // A label and its control read as one row only so far apart:
                // full-screen, they sat at opposite edges. The column
                // stands in the middle of the pane, not against the section list.
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color.Vedivox.bg)
        }
        // Embedded in the main window's detail pane (sidebar Settings, ⌘,).
        .frame(minWidth: 700, idealWidth: 780, maxWidth: .infinity,
               minHeight: 480, idealHeight: 560, maxHeight: .infinity)
    }

    private var navigator: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
            ForEach(Section.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: VedivoxSpace.m) {
                        Image(systemName: item.icon)
                            .frame(width: 16)
                            .foregroundStyle(section == item ? Color.Vedivox.fg : Color.Vedivox.fgSecondary)
                        Text(item.label)
                            .vedivoxFont(.row)
                            .foregroundStyle(section == item ? Color.Vedivox.fg : Color.Vedivox.fgSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VedivoxSpace.m)
                    .padding(.vertical, VedivoxSpace.s)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: VedivoxRadius.s)
                            .fill(section == item ? Color.Vedivox.bgActive : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.section.\(item.rawValue)")
            }
            Spacer()
        }
        .padding(VedivoxSpace.l)
        .frame(width: 214)
        // Content ground, not the sidebar's: on bgSidebar this column merged
        // with the main sidebar beside it (owner's review, build 1010).
        .background(Color.Vedivox.bg)
    }
}

// MARK: - Building blocks

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.m) {
            VedivoxSectionHeader(title: title)
            VStack(alignment: .leading, spacing: VedivoxSpace.l) {
                content
            }
            .padding(VedivoxSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.m))
            .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.m).strokeBorder(Color.Vedivox.lineSoft))
        }
        .padding(.bottom, VedivoxSpace.xl)
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    var caption: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                Text(label)
                    .vedivoxFont(.transcript)
                    .foregroundStyle(Color.Vedivox.fg)
                if let caption {
                    Text(caption)
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            content
                .labelsHidden()
        }
    }
}

// MARK: - My Voice (owner-voice-enrollment)

private struct MyVoiceSection: View {
    @Environment(AppState.self) private var appState
    @StateObject private var recorder = VoiceEnrollmentRecorder()
    @State private var isProcessing = false
    @State private var enrolledAt: Date?
    @State private var errorText: String?

    private static let sampleText = """
    Reading tip: speak the way you do on calls. "I usually start my day by \
    going through yesterday's notes, then I pick the one thing that matters \
    most and work on it before any meetings. In the afternoon I catch up on \
    messages, review what the team shipped, and write down what I want to \
    tackle tomorrow morning."
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "My Voice") {
                Text("Record 20–30 seconds of your normal speaking voice in a quiet room. Vedivox uses it to recognize you on the microphone track from day one — no meetings needed. It also lets Vedivox tell other voices on your mic apart from yours.")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.sampleText)
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(VedivoxSpace.l)
                    .background(Color.Vedivox.bg, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))

                if recorder.isRecording {
                    recordingControls
                } else if isProcessing {
                    HStack(spacing: VedivoxSpace.m) {
                        ProgressView().controlSize(.small)
                        Text("Processing recording…")
                            .vedivoxFont(.caption)
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                    }
                } else {
                    idleControls
                }

                if let errorText {
                    Text(errorText)
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.danger)
                }
            }
        }
        .task { await loadEnrollmentDate() }
    }

    private var idleControls: some View {
        SettingsRow(
            label: enrolledAt == nil ? "No recording yet" : "Voice recorded",
            caption: enrolledAt.map { "Recorded \($0.formatted(date: .abbreviated, time: .shortened)). Recording again replaces it." }
        ) {
            Button(enrolledAt == nil ? "Record" : "Record Again") {
                errorText = nil
                do { try recorder.start() } catch {
                    errorText = "Could not start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    private var recordingControls: some View {
        HStack(spacing: VedivoxSpace.l) {
            Circle().fill(Color.Vedivox.recording).frame(width: VedivoxSize.dot, height: VedivoxSize.dot)
            Text(timerText)
                .vedivoxFont(.tabular)
            ProgressView(value: recorder.level)
                .frame(maxWidth: 160)
            Spacer()
            Button("Cancel") { recorder.cancel() }
            Button("Stop") { finishRecording() }
                .disabled(!recorder.reachedMinimum)
                .help(recorder.reachedMinimum
                      ? "Stop and save"
                      : "Keep talking — at least \(Int(VoiceEnrollment.minimumSeconds)) seconds needed")
        }
    }

    private var timerText: String {
        let s = Int(recorder.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func finishRecording() {
        guard let url = recorder.stop() else { return }
        isProcessing = true
        Task {
            do {
                try await enroll(recording: url)
                enrolledAt = Date()
            } catch {
                Log.error("Voice enrollment failed: \(error)")
                errorText = "Enrollment failed: \(error.localizedDescription)"
            }
            isProcessing = false
        }
    }

    /// Replace the previous take, import the recording as a regular meeting,
    /// run the standard pipeline, pin everything to "me" (design § решение 1).
    private func enroll(recording: URL) async throws {
        if let old = VoiceEnrollment.enrollmentMeetingId {
            try await VoiceEnrollment.deleteEnrollmentMeeting(old)
            VoiceEnrollment.enrollmentMeetingId = nil
        }

        let meetingId = UUID().uuidString
        let audioDir = try DatabaseManager.audioDirectory(for: meetingId)
        let dest = audioDir.appendingPathComponent("original.m4a")
        try FileManager.default.moveItem(at: recording, to: dest)

        let meeting = Meeting(
            id: meetingId,
            title: VoiceEnrollment.meetingTitle,
            startTime: Date(),
            source: .import,
            sourceFilePath: dest.path,
            status: .transcribing
        )
        try await MeetingRepository().save(meeting)
        await appState.loadMeetings()

        try await appState.pipeline.processImportedFile(meetingId: meetingId, fileURL: dest)
        try await VoiceEnrollment.claimSegmentsForMe(meetingId: meetingId)

        VoiceEnrollment.enrollmentMeetingId = meetingId
        appState.transcriptVersion += 1
        await appState.loadMeetings()
    }

    private func loadEnrollmentDate() async {
        guard let id = VoiceEnrollment.enrollmentMeetingId else { return }
        enrolledAt = try? await MeetingRepository().find(id)?.startTime
    }
}

// MARK: - General

private struct GeneralSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage("voxTheme") private var vedivoxTheme: VedivoxTheme = .dark
    @AppStorage(VedivoxPalette.defaultsKey) private var vedivoxPalette: VedivoxPalette = .mono
    @AppStorage("menuBarAlwaysVisible") private var menuBarAlwaysVisible = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Appearance") {
                SettingsRow(label: "Theme") {
                    VedivoxPicker(selection: $vedivoxTheme, options: VedivoxTheme.allCases.map { ($0, $0.label) })
                    .frame(width: 160)
                }
                SettingsRow(label: "Palette", caption: "Mono is monochrome; Ink & Yellow is ink blue with yellow accents") {
                    VedivoxPicker(selection: $vedivoxPalette, options: VedivoxPalette.allCases.map { ($0, $0.label) })
                    .frame(width: 160)
                }
            }

            SettingsGroup(title: "System") {
                SettingsRow(label: "Launch at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                Log.error("Login item toggle failed: \(error.localizedDescription)")
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
                SettingsRow(label: "Menu bar icon") {
                    VedivoxPicker(selection: $menuBarAlwaysVisible, options: [(true, "Always"), (false, "Only while recording")])
                    .frame(width: 160)
                    // AppStorage alone doesn't reach the live controller —
                    // without this the picker only takes effect after restart.
                    .onChange(of: menuBarAlwaysVisible) { _, visible in
                        appState.menuBarController.alwaysVisible = visible
                    }
                }
            }
        }
    }
}

// MARK: - Recording

private struct RecordingSection: View {
    @AppStorage("selectedMicDeviceUID") private var selectedDeviceUID = ""
    @AppStorage(MeetingLiveTranscript.enabledKey) private var liveTranscript = true
    @State private var inputDevices: [(uid: String, name: String)] = []
    @AppStorage(MicPriority.enabledKey) private var micPriorityEnabled = false
    @State private var micPriority = MicPriority.load()
    @State private var connectedInputs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Audio") {
                SettingsRow(
                    label: "Microphone priority",
                    caption: micPriorityEnabled
                        ? "Recordings and dictation open the first connected microphone in this list. Drag to reorder."
                        : nil
                ) {
                    Toggle("", isOn: $micPriorityEnabled).toggleStyle(.switch)
                        // Turning it on starts the list from the microphone picked below.
                        .onChange(of: micPriorityEnabled) { _, enabled in
                            if enabled { loadInputDevices() }
                        }
                }
                if micPriorityEnabled {
                    MicPriorityList(list: $micPriority, connected: connectedInputs)
                        .onChange(of: micPriority) { _, list in list.save() }
                } else {
                    SettingsRow(label: "Microphone", caption: "Also used for dictation") {
                        VedivoxPicker(selection: $selectedDeviceUID, options: [("", "System default")] + inputDevices.map { ($0.uid, $0.name) })
                        .frame(width: 220)
                    }
                }
                SettingsRow(
                    label: "Live transcript while recording",
                    caption: "Lets the vedivox command line and Claude read the meeting while it is recorded. Kept in memory only; applies from the next recording."
                ) {
                    Toggle("", isOn: $liveTranscript).toggleStyle(.switch)
                }
            }

            SystemCaptureExclusionsGroup()
        }
        .task {
            loadInputDevices()
            // Current / Unavailable follow a plug while the section is open.
            for await _ in AudioDeviceChanges.stream() { loadInputDevices(keepSelection: true) }
        }
    }

    /// `keepSelection`: a mic unplugged while Settings is open stays picked,
    /// as it does when unplugged anywhere else.
    private func loadInputDevices(keepSelection: Bool = false) {
        let devices = MicPriority.connectedInputs()
        inputDevices = devices.map { (uid: $0.uid, name: $0.name) }
        connectedInputs = Set(devices.map(\.uid))
        // Only a list in use is written: until then it starts from the picker.
        if micPriorityEnabled {
            micPriority = MicPriority.load()
            micPriority.remember(devices)
            micPriority.save()
        }

        if !keepSelection, !selectedDeviceUID.isEmpty,
           !devices.contains(where: { $0.uid == selectedDeviceUID }) {
            selectedDeviceUID = ""
        }
    }
}

/// Apps kept out of the system-audio tap. Read by the capture at
/// every tap build, so an edit applies to the next recording without relaunch.
private struct SystemCaptureExclusionsGroup: View {
    @AppStorage(SystemCaptureExclusions.defaultsKey)
    private var bundleIDsJSON = SystemCaptureExclusions.defaultJSON

    private var bundleIDs: [String] { SystemCaptureExclusions.decode(bundleIDsJSON) }

    var body: some View {
        SettingsGroup(title: "Not recorded in system audio") {
            Text("Sound from these apps stays out of the system audio track. Add apps that feed your microphone (OBS, Loopback) or play their own notification sounds.")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(bundleIDs, id: \.self) { bundleID in
                let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                HStack(spacing: VedivoxSpace.m) {
                    Image(nsImage: appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                        ?? NSWorkspace.shared.icon(for: .application))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(appURL.map { $0.deletingPathExtension().lastPathComponent } ?? bundleID)
                        .vedivoxFont(.transcript)
                        .foregroundStyle(Color.Vedivox.fg)
                    Spacer()
                    Button {
                        bundleIDsJSON = SystemCaptureExclusions.encode(bundleIDs.filter { $0 != bundleID })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.vedivoxIcon)
                    .help("Remove")
                }
            }
            Button("Add App\u{2026}", action: addApps)
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let current = bundleIDs
        let added = panel.urls
            .compactMap { Bundle(url: $0)?.bundleIdentifier }
            .filter { id in !current.contains { $0.caseInsensitiveCompare(id) == .orderedSame } }
        bundleIDsJSON = SystemCaptureExclusions.encode(current + added)
    }
}

private struct CalendarGroup: View {
    @Environment(AppState.self) private var appState
    @AppStorage("watchedCalendarIDs") private var watchedCalendarIDsJSON = "[]"
    @State private var calendars: [(id: String, title: String, isWatched: Bool)] = []
    @State private var grant = PermissionFacts.Grant(CalendarService().authorizationStatus)
    @State private var calendarService = CalendarService()

    var body: some View {
        SettingsGroup(title: "Calendar") {
            // Without it the list reads like a detection filter; it is not (MeetingDetector).
            Text("When Vedivox detects a meeting, an event from a checked calendar gives the recording its title and series. Detection itself does not depend on the calendar.")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Calendars carried over from Vox stay checked without access: said here. // rename:keep
            SettingsRow(
                label: "Calendar access",
                caption: PermissionFacts.calendarStatus(grant, checked: decodeWatchedIDs().count)
            ) {
                if grant != .allowed {
                    if PermissionFacts.action(grant, canAsk: true) == .ask {
                        Button("Allow") {
                            Task { await grantAccess() }
                        }
                    } else {
                        OpenSystemSettingsButton(url: OpenSystemSettingsButton.privacy("Privacy_Calendars"))
                    }
                }
            }
            ForEach(calendars.indices, id: \.self) { index in
                SettingsRow(label: calendars[index].title) {
                    Toggle("", isOn: Binding(
                        get: { calendars[index].isWatched },
                        set: { newValue in
                            calendars[index].isWatched = newValue
                            saveWatchedIDs()
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }
        }
        .task { await loadCalendars() }
    }

    private func grantAccess() async {
        _ = await calendarService.requestAccess()
        await loadCalendars()
    }

    private func loadCalendars() async {
        grant = PermissionFacts.Grant(calendarService.authorizationStatus)
        guard grant == .allowed else { return }
        let watchedIDs = decodeWatchedIDs()
        let ekCalendars = await calendarService.availableCalendars()
        calendars = ekCalendars.map { cal in
            (id: cal.id, title: cal.title, isWatched: watchedIDs.contains(cal.id))
        }
    }

    private func saveWatchedIDs() {
        let ids = calendars.filter(\.isWatched).map(\.id)
        if let data = try? JSONEncoder().encode(ids),
           let str = String(data: data, encoding: .utf8) {
            watchedCalendarIDsJSON = str
        }
        Task { await appState.applyDetectionConfig() }
    }

    private func decodeWatchedIDs() -> Set<String> { Self.decodeIDs(watchedCalendarIDsJSON) }

    static func decodeIDs(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }
}

// MARK: - Meetings

private struct MeetingsSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage(MeetingAutomation.detectionEnabledKey)
    private var detectionEnabled = MeetingAutomation.detectionEnabledByDefault
    @AppStorage("detectZoom") private var detectZoom = true
    @AppStorage("detectGoogleMeet") private var detectGoogleMeet = true
    @AppStorage("detectSlackHuddle") private var detectSlackHuddle = true
    @AppStorage("detectTeams") private var detectTeams = true
    @AppStorage("detectTelemost") private var detectTelemost = false
    @AppStorage(MeetingAutomation.autoStartKey) private var autoStart = false
    @AppStorage(MeetingAutomation.autoStopKey) private var autoStop = false
    @AppStorage(MeetingAutomation.endThresholdKey)
    private var endThreshold = MeetingAutomation.defaultEndThreshold
    @AppStorage(MeetingAutomation.reminderIntervalKey)
    private var reminderInterval = MeetingAutomation.defaultReminderInterval
    @AppStorage(MeetingAutomation.autoStopDelayKey)
    private var autoStopDelay = MeetingAutomation.defaultAutoStopDelay
    @AppStorage(MeetingAutomation.speechHoldKey)
    private var speechHold = MeetingAutomation.defaultSpeechHold

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Meeting detection") {
                SettingsRow(
                    label: "Detect meetings automatically",
                    caption: detectionEnabled
                        ? nil
                        : "Notices calls in Zoom, Google Meet, Slack, Microsoft Teams and Yandex Telemost, then reminds you to record or records on its own. Its options and the calendars appear when it is on."
                ) {
                    Toggle("", isOn: $detectionEnabled)
                        .toggleStyle(.switch)
                        // AppStorage alone doesn't reach the running monitors —
                        // without this the toggle only applies after a relaunch.
                        .onChange(of: detectionEnabled) { _, enabled in
                            Task {
                                if enabled {
                                    await appState.startDetection()
                                } else {
                                    await appState.stopDetection()
                                }
                            }
                        }
                }
                // Everything below works only with detection (2.5):
                // hidden while it is off rather than a block of dimmed rows.
                if detectionEnabled {
                    SettingsRow(label: "Zoom") {
                        Toggle("", isOn: $detectZoom).toggleStyle(.switch)
                    }
                    SettingsRow(label: "Google Meet") {
                        Toggle("", isOn: $detectGoogleMeet).toggleStyle(.switch)
                    }
                    SettingsRow(label: "Slack Huddles") {
                        Toggle("", isOn: $detectSlackHuddle).toggleStyle(.switch)
                    }
                    SettingsRow(label: "Microsoft Teams") {
                        Toggle("", isOn: $detectTeams).toggleStyle(.switch)
                    }
                    SettingsRow(label: "Yandex Telemost", caption: "The app and calls in a browser tab") {
                        Toggle("", isOn: $detectTelemost).toggleStyle(.switch)
                    }
                    SettingsRow(label: "When a meeting starts") {
                        VedivoxPicker(selection: $autoStart, options: [(false, "Notify me"), (true, "Start recording")])
                            .frame(width: 220)
                    }
                    SettingsRow(
                        label: "When a meeting ends",
                        caption: autoStop
                            ? "Warns with a countdown first; a call that comes back within 2 minutes records again"
                            : "Reminds you to stop until the meeting resumes or the recording stops; no repeats while the mic hears speech"
                    ) {
                        VedivoxPicker(selection: $autoStop, options: [(false, "Remind me to stop"), (true, "Stop recording")])
                            .frame(width: 220)
                    }
                    if autoStop {
                        SettingsRow(
                            label: "Stop recording after",
                            caption: "This long after the call stops using the mic (Google Meet, Telemost in a browser: the browser\u{2019}s audio)"
                        ) {
                            VedivoxPicker(selection: $autoStopDelay, options: Self.choices([5, 10, 15, 30, 60, 120], including: autoStopDelay))
                                .frame(width: 220)
                        }
                    } else {
                        SettingsRow(
                            label: "Meeting counts as ended after",
                            caption: "This long after the call stops using the mic (Google Meet, Telemost in a browser: the browser\u{2019}s audio). Starts the reminders."
                        ) {
                            VedivoxPicker(selection: $endThreshold, options: Self.choices([10, 15, 30, 60], including: endThreshold))
                                .frame(width: 220)
                        }
                        SettingsRow(label: "Reminder interval") {
                            VedivoxPicker(selection: $reminderInterval, options: Self.choices([30, 60, 120, 300], including: reminderInterval))
                                .frame(width: 220)
                        }
                    }
                    SettingsRow(
                        label: "Wait after speech",
                        caption: "The mic heard you this recently: the conversation goes on, so no \(autoStop ? "stop" : "repeat reminder") yet"
                    ) {
                        VedivoxPicker(selection: $speechHold, options: Self.choices([0, 5, 10, 30], including: speechHold))
                            .frame(width: 220)
                    }
                }
            }
            // Without this the per-app toggles only applied after a relaunch.
            .onChange(of: [detectZoom, detectGoogleMeet, detectSlackHuddle, detectTeams, detectTelemost]) {
                Task { await appState.applyDetectionConfig() }
            }
            // The detector's end threshold depends on all three (`detectorThreshold`).
            .onChange(of: [endThreshold, autoStopDelay, autoStop ? 1 : 0]) {
                Task { await appState.applyDetectionConfig() }
            }

            if detectionEnabled {
                CalendarGroup()
            }
        }
    }

    /// Durations in seconds, plus a value set by hand (`defaults write`) so the
    /// picker shows it instead of a blank.
    private static func choices(_ presets: [Double], including value: Double) -> [(Double, String)] {
        (presets.contains(value) ? presets : [value] + presets)
            .map { ($0, $0 == 0 ? "Off" : $0 < 60 ? "\(Int($0)) s" : "\(Int($0 / 60)) min") }
    }
}

// MARK: - Transcript

private struct TranscriptSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage(ForeignVoiceDefault.defaultsKey)
    private var foreignVoiceDefault = ForeignVoiceDefault.fallback
    @AppStorage(ExclusionToggle.Config.autoExpiryKey)
    private var exclusionAutoExpiry = ExclusionToggle.Config.defaultAutoExpiry
    @AppStorage(MuteMonitor.enabledKey) private var zoomMuteExclusion = true
    @State private var accessibilityGranted = AXIsProcessTrusted()
    /// Same reading as `DiarizationService.useOfflineDiarizer`: unset means offline.
    @State private var useOfflineDiarizer: Bool = {
        if UserDefaults.standard.object(forKey: "useOfflineDiarizer") == nil { return true }
        return UserDefaults.standard.bool(forKey: "useOfflineDiarizer")
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Hidden from the transcript") {
                SettingsRow(
                    label: "Hide speech while muted in Zoom or Teams",
                    caption: accessibilityGranted
                        ? "What you say on the mic while muted in Zoom or the new Microsoft Teams stays out of the transcript. English interface only."
                        : "Needs the Accessibility permission, which Vedivox doesn\u{2019}t have yet."
                ) {
                    HStack(spacing: VedivoxSpace.m) {
                        if !accessibilityGranted {
                            Button("Open Settings") {
                                if let url = URL(
                                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                                ) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.vedivoxGhost)
                        }
                        Toggle("", isOn: $zoomMuteExclusion).toggleStyle(.switch)
                    }
                }
                SettingsRow(
                    label: "\u{201C}Not in transcript\u{201D} turns off after",
                    caption: exclusionCaption
                ) {
                    VedivoxPicker(
                        selection: $exclusionAutoExpiry,
                        options: expiryChoices.map { ($0, $0 == 0 ? "Never" : "\(Int($0 / 60)) min") }
                    )
                    .frame(width: 220)
                }
                SettingsRow(
                    label: "Foreign voices on the mic",
                    caption: "Speech on the mic that isn\u{2019}t yours. Needs your voice (My Voice). Applies when a recording is processed; a per-meeting choice overrides it."
                ) {
                    VedivoxPicker(selection: $foreignVoiceDefault, options: ForeignVoiceDefault.allCases.map { ($0, $0.title) })
                    .frame(width: 220)
                }
            }

            SettingsGroup(title: "Speech recognition") {
                SettingsRow(
                    label: "ASR model",
                    caption: "FluidAudio, on-device on the Neural Engine"
                ) {
                    Text("Parakeet TDT")
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }
                SettingsRow(
                    label: "Languages",
                    caption: "About 25 European languages, detected automatically. Others, such as Japanese or Arabic, come out as nonsense."
                ) {
                    EmptyView()
                }
                SettingsRow(
                    label: "Diarization",
                    caption: "FluidAudio, on-device. Offline clusters the whole recording at once (VBx); Online is the older pipeline. Applies to the next processing or reprocess."
                ) {
                    VedivoxPicker(selection: $useOfflineDiarizer, options: [(true, "Offline"), (false, "Online")])
                        .frame(width: 160)
                        .onChange(of: useOfflineDiarizer) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "useOfflineDiarizer")
                        }
                }
                SettingsRow(
                    label: "Vocabulary",
                    caption: "Fixes how terms and names are spelled. Edits apply to the next processing and dictation; for an older meeting use Reprocess."
                ) {
                    Button("Open") {
                        _ = TermNormalizer.loadVocabulary() // seeds the file from the template if missing
                        NSWorkspace.shared.open(TermNormalizer.vocabularyURL)
                    }
                }
            }
        }
        // The grant happens in System Settings; re-check when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    private var exclusionCaption: String {
        let turnedOn = appState.shortcutText(.toggleExclusion).map { "with \($0) or " } ?? ""
        return "Turned on \(turnedOn)from the menu bar while recording. Applies the next time you turn it on."
    }

    /// The presets, plus a value set by hand (`defaults write`) so the picker
    /// shows it instead of a blank.
    private var expiryChoices: [Double] {
        let presets: [Double] = [300, 900, 1800, 3600, 7200, 0]
        return presets.contains(exclusionAutoExpiry) ? presets : [exclusionAutoExpiry] + presets
    }
}

// MARK: - Dictation

/// Replaces the disabled «Появится вместе с Phase 9» toggle, which claimed
/// dictation did not exist while it was working — the same class of untruth as
/// the loading banner's «first run»,
/// and adds the live-draft chunk setting.
private struct DictationSection: View {
    @AppStorage(DictationChunkSize.defaultsKey) private var chunkMs = DictationChunkSize.default.rawValue
    @AppStorage(DictationBackgroundAudio.defaultsKey) private var backgroundAudio = DictationBackgroundAudio.default
    @State private var accessibilityGranted = AXIsProcessTrusted()

    private var selected: DictationChunkSize {
        DictationChunkSize(rawValue: chunkMs) ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Dictation") {
                SettingsRow(
                    label: "Keyboard shortcut",
                    caption: "Press to start, press again to insert the recognized text. Escape cancels"
                ) {
                    // The same name as in Shortcuts: a change in either place is the one shortcut.
                    ShortcutRecorder(name: .toggleDictation)
                }

                SettingsRow(label: "While dictating", caption: backgroundAudio.explanation) {
                    VedivoxPicker(selection: $backgroundAudio, options: DictationBackgroundAudio.allCases.map { ($0, $0.title) })
                        .fixedSize()
                }

                SettingsRow(
                    label: "Accessibility",
                    caption: accessibilityGranted
                        ? "Allowed: the text is typed where your cursor is."
                        : "Not allowed: the text stays on the clipboard, and Escape also reaches the app you are typing in. After allowing it, restart Vedivox."
                ) {
                    if accessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.Vedivox.success)
                    } else {
                        OpenSystemSettingsButton(url: OpenSystemSettingsButton.privacy("Privacy_Accessibility"))
                    }
                }
            }

            SettingsGroup(title: "Draft while you speak") {
                // The wait on switching and that the draft is not what gets
                // inserted: two things the user cannot infer.
                SettingsRow(
                    label: "How soon it appears",
                    caption: "\(selected.explanation). Each option is a separate 640 MB model: after switching, the first dictation waits for the download. "
                        + "The shown text is a draft — the more accurate final transcription is what gets inserted."
                ) {
                    VedivoxPicker(selection: $chunkMs, options: DictationChunkSize.allCases.map { ($0.rawValue, $0.title) })
                        .fixedSize()
                }
            }
        }
        // The grant happens in System Settings; re-check when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }
}

/// Opens a pane of System Settings.
private struct OpenSystemSettingsButton: View {
    let url: String

    /// A pane of Privacy & Security, such as `Privacy_Accessibility`.
    static func privacy(_ pane: String) -> String {
        "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    }

    var body: some View {
        Button("Open Settings") {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(.vedivoxGhost)
    }
}

/// A recorder for one reassignable Vedivox shortcut. A shortcut owned by another
/// Vedivox command is refused with its name; the package itself checks the system
/// and the menu.
private struct ShortcutRecorder: View {
    @Environment(AppState.self) private var appState
    let name: KeyboardShortcuts.Name

    /// Posted by `KeyboardShortcuts.Recorder` (internal name in the package).
    private static let recorderActiveNotification = Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange")

    var body: some View {
        KeyboardShortcuts.Recorder(for: name) { _ in
            appState.shortcutsRevision += 1
        }
        .shortcutValidation { shortcut in
            let current = MainActor.assumeIsolated { AppShortcuts.currentShortcuts }
            guard let owner = AppShortcuts.conflictingTitle(for: shortcut, excluding: name, current: current) else {
                return .allow
            }
            return .disallow(reason: "Already used by “\(owner)”")
        }
        // The package only mutes handlers while a recorder listens; the Carbon
        // hotkeys stay registered and swallow their keystroke, so another Vedivox
        // global (⇧⌘2) never reached the recorder and its conflict message.
        // Unregister them for the duration.
        .onReceive(NotificationCenter.default.publisher(for: Self.recorderActiveNotification)) { note in
            KeyboardShortcuts.isEnabled = !((note.userInfo?["isActive"] as? Bool) ?? false)
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage("seekStepSeconds") private var seekStep = 5.0

    private static let captions: [KeyboardShortcuts.Name: String] = [
        .toggleRecording: "From any app, also while dictating",
        .playerSlower: "When the cursor is not in a text field",
        .playerFaster: "When the cursor is not in a text field",
        .toggleExclusion: "While a meeting is recording",
        .findInView: "Meetings, speakers, series — in the open section",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AppShortcuts.Group.allCases, id: \.self) { group in
                SettingsGroup(title: group.rawValue) {
                    ForEach(AppShortcuts.catalog.filter { $0.group == group }, id: \.name) { entry in
                        SettingsRow(label: entry.title, caption: Self.captions[entry.name]) {
                            ShortcutRecorder(name: entry.name)
                        }
                    }
                    if group == .player { playerRows }
                }
            }

            // The Listen section's keys (listen-queue § 7); like the player
            // keys, only while the cursor is not in a text field.
            SettingsGroup(title: "Listen") {
                shortcutRow("Play / pause the fragment", "Space")
                shortcutRow("Previous / next fragment", "← / →")
                shortcutRow("Previous / next voice", "↑ / ↓")
                shortcutRow("This is candidate 1, 2, 3", "1 / 2 / 3")
                shortcutRow("Hear candidate 1, 2, 3", "⌥1 / ⌥2 / ⌥3")
                shortcutRow("New person", "N", caption: "Type the name, Return applies, Esc cancels")
                shortcutRow("Other speaker", "/", caption: "Search confirmed speakers")
                shortcutRow("Split between candidates 1 and 2", "X", caption: "Two people in one voice")
                shortcutRow("Skip", "S")
                shortcutRow("Open in meeting", "O")
            }

            // Fixed keys of the window, not reassignable.
            SettingsGroup(title: "Window") {
                shortcutRow("Settings", "⌘,")
                shortcutRow("Clear the search, then leave it", "Esc")
                shortcutRow("Leave editing, then clear the selection", "Esc", caption: "In the transcript")
                shortcutRow("Clear the selection", "Esc", caption: "In Speakers")
                shortcutRow("Delete meeting", "⌘⌫", caption: "In a text field with text before the cursor, it deletes that text instead")
                shortcutRow("Move the cut by a second", "← / →", caption: "In Split")
                shortcutRow("Move the cut to the previous / next segment", "⌥← / ⌥→", caption: "In Split")
                shortcutRow("Move the chosen bound by a second / to the next segment", "← → / ⌥← ⌥→", caption: "In Trim")
                shortcutRow("Switch between Start and End", "Tab", caption: "In Trim")
            }

            HStack {
                Text("Every shortcut on this page that can be changed, the player keys included")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                Spacer()
                Button("Restore Defaults") {
                    KeyboardShortcuts.reset(AppShortcuts.catalog.map(\.name))
                    appState.shortcutsRevision += 1
                    UserDefaults.standard.removeObject(forKey: "seekStepSeconds")
                }
            }
            .padding(.bottom, VedivoxSpace.xl)
        }
    }

    /// The player's fixed keys and the seek step, under its reassignable rate shortcuts.
    @ViewBuilder private var playerRows: some View {
        SettingsRow(label: "Seek step ←/→") {
            // The value sits outside the Stepper: SettingsRow hides
            // control labels, and the Stepper's label was the value.
            HStack(spacing: VedivoxSpace.s) {
                Text("\(Int(seekStep)) s")
                    .vedivoxFont(.timecode)
                Stepper("Seek step", value: $seekStep, in: 1 ... 60, step: 1)
            }
            .fixedSize()
        }
        // The fixed player keys carry their condition, because it is
        // real and invisible: they are delivered through focus, so they
        // act on the player only when the caret is not in a text field.
        shortcutRow("Play / Pause", "Space", caption: "When the cursor is not in a text field")
        shortcutRow("Seek", "← / →", caption: "When the cursor is not in a text field")
    }

    private func shortcutRow(_ label: String, _ keys: String, caption: String? = nil) -> some View {
        SettingsRow(label: label, caption: caption) {
            Text(keys)
                .vedivoxFont(.timecode)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .padding(.horizontal, VedivoxSpace.m)
                .padding(.vertical, VedivoxSpace.xs)
                .background(Color.Vedivox.bgInput, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
                .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.s).strokeBorder(Color.Vedivox.line))
        }
    }
}

// MARK: - Storage

private struct StorageSection: View {
    @State private var sizes = Sizes()
    @State private var backupResult: String?
    @AppStorage("debugLogging") private var debugLogging = false

    private struct Sizes {
        var database = "…", audio = "…", models = "…", backups = "…", logs = "…"
    }

    private var appSupportURL: URL { DataDirectory.root }
    private var databaseURL: URL { appSupportURL.appendingPathComponent("Vedivox.sqlite") }
    private var audioURL: URL { appSupportURL.appendingPathComponent("audio") }
    private var backupsURL: URL { DatabaseSafety.backupsDirectory(in: appSupportURL) }
    private var logsURL: URL { appSupportURL.appendingPathComponent("logs") }
    /// FluidAudio's own location, outside Vedivox's data directory (ModelHub).
    private static let modelsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models", isDirectory: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Every row: `~/path · size`, at most one line of why, Show in Finder.
            SettingsGroup(title: "Data") {
                SettingsRow(label: "Database", caption: StorageCaption.text(databaseURL, size: sizes.database)) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([databaseURL]) }
                }
                SettingsRow(label: "Meeting audio", caption: StorageCaption.text(audioURL, size: sizes.audio)) {
                    Button("Show in Finder") { NSWorkspace.shared.open(audioURL) }
                }
                SettingsRow(
                    label: "Speech models",
                    caption: StorageCaption.text(
                        Self.modelsURL, size: sizes.models, note: "Downloaded again if deleted; not removed with Vedivox."
                    )
                ) {
                    Button("Show in Finder") { NSWorkspace.shared.open(Self.modelsURL) }
                }
                SettingsRow(
                    label: "Automatic backups",
                    caption: StorageCaption.text(
                        backupsURL, size: sizes.backups,
                        note: "The newest \(DatabaseSafety.backupsToKeep), made before an update changes the database."
                    )
                ) {
                    Button("Show in Finder") { NSWorkspace.shared.open(backupsURL) }
                }
                SettingsRow(label: "Logs", caption: StorageCaption.text(logsURL, size: sizes.logs)) {
                    Button("Show in Finder") { NSWorkspace.shared.open(logsURL) }
                }
                SettingsRow(
                    label: "Debug logging",
                    caption: "More detail in the logs, for a bug report"
                ) {
                    Toggle("", isOn: $debugLogging)
                        .toggleStyle(.switch)
                        .onChange(of: debugLogging) {
                            Log.level = debugLogging ? .debug : .info
                        }
                }
            }

            SettingsGroup(title: "Backup") {
                SettingsRow(
                    label: "Database backup",
                    caption: backupResult ?? "A copy of Vedivox.sqlite (without audio) to a location you choose"
                ) {
                    Button("Save a Copy…") { runBackup() }
                }
            }
        }
        .task { await computeSizes() }
    }

    private func runBackup() {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Vedivox-backup-\(stamp).sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await DatabaseManager.shared.backup(to: url)
                backupResult = "Saved: \(url.lastPathComponent)"
            } catch {
                backupResult = "Error: \(error.localizedDescription)"
                Log.error("DB backup failed: \(error)")
            }
        }
    }

    private func computeSizes() async {
        let support = appSupportURL
        let backups = backupsURL
        let logs = logsURL
        let models = Self.modelsURL
        sizes = await Task.detached(priority: .utility) { () -> Sizes in
            func directorySize(_ url: URL) -> Int64 {
                var total: Int64 = 0
                if let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.fileSizeKey]
                ) {
                    for case let file as URL in enumerator {
                        total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
                return total
            }
            // The WAL holds recent writes until a checkpoint: on a young
            // database Vedivox.sqlite alone reads "Zero KB".
            let dbBytes = ["Vedivox.sqlite", "Vedivox.sqlite-wal", "Vedivox.sqlite-shm"].reduce(Int64(0)) { total, name in
                let attributes = try? FileManager.default.attributesOfItem(atPath: support.appendingPathComponent(name).path)
                return total + ((attributes?[.size] as? Int64) ?? 0)
            }
            let formatter = ByteCountFormatter()
            return Sizes(
                database: formatter.string(fromByteCount: dbBytes),
                audio: formatter.string(fromByteCount: directorySize(support.appendingPathComponent("audio"))),
                models: formatter.string(fromByteCount: directorySize(models)),
                backups: formatter.string(fromByteCount: directorySize(backups)),
                logs: formatter.string(fromByteCount: directorySize(logs))
            )
        }.value
    }
}

// MARK: - Privacy & Permissions

private struct PrivacySection: View {
    @Environment(AppState.self) private var appState
    @AppStorage("watchedCalendarIDs") private var watchedCalendarIDsJSON = "[]"
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var calendarStatus = CalendarService().authorizationStatus
    /// Unknown until read: the read is async, and it is skipped outside an app bundle.
    @State private var notifications = PermissionFacts.Grant.unknown
    @State private var systemAudio = PermissionFacts.systemAudio()
    /// The last Check on this screen; its words stay until a proof replaces them.
    @State private var systemAudioCheck: PermissionFacts.SystemAudioCheck?
    @State private var checkingSystemAudio = false
    @State private var automation = PermissionFacts.Row(grant: .unknown, caption: PermissionFacts.automationPurpose)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Data") {
                SettingsRow(
                    label: "Everything stays local",
                    caption: "Vedivox sends no audio, transcripts, or telemetry anywhere. Recordings, the database, and logs live only on this Mac. It goes online only to download its speech models from Hugging Face and, if Check for updates is on, to ask GitHub for the latest release."
                ) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(Color.Vedivox.success)
                }
            }

            // Statuses come from macOS; the grants themselves happen in
            // System Settings (8.3). One column of marks, one of
            // buttons, and every caption starts with the status.
            SettingsGroup(title: "Permissions") {
                row(
                    "Microphone",
                    PermissionFacts.Row(micGrant, purpose: "Your side of a meeting, and dictation."),
                    pane: "Privacy_Microphone",
                    ask: { _ = await AVCaptureDevice.requestAccess(for: .audio) }
                )
                // Check: for whoever went through the wizard before it asked
                // for real. Not next to a recording — that one proves it.
                row(
                    "System audio",
                    systemAudio,
                    pane: "Privacy_ScreenCapture",
                    check: appState.recordingVM.isRecording ? nil : {
                        systemAudioCheck = await PermissionFacts.checkSystemAudio()
                    }
                )
                row(
                    "Accessibility",
                    PermissionFacts.Row(
                        accessibilityGranted ? .allowed : .refused,
                        purpose: "Types dictation into other apps; reads the mute state in Zoom and Teams."
                    ),
                    pane: "Privacy_Accessibility"
                )
                row(
                    "Calendars",
                    PermissionFacts.calendars(.init(calendarStatus), checked: CalendarGroup.decodeIDs(watchedCalendarIDsJSON).count),
                    pane: "Privacy_Calendars",
                    ask: { _ = await appState.calendarService.requestAccess() }
                )
                row(
                    "Notifications",
                    PermissionFacts.Row(
                        notifications,
                        purpose: "Detected meetings, reminders to stop, a recording started from the command line."
                    ),
                    url: "x-apple.systempreferences:com.apple.preference.notifications",
                    ask: { _ = await appState.notificationService.requestPermission() }
                )
                row("Automation", automation, pane: "Privacy_Automation")
            }
        }
        .task { await refresh() }
        // The grants happen in System Settings; re-check when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var micGrant: PermissionFacts.Grant {
        switch micStatus {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .refused
        }
    }

    private func refresh() async {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
        calendarStatus = CalendarService().authorizationStatus
        systemAudio = PermissionFacts.systemAudio(check: systemAudioCheck)
        // UNUserNotificationCenter traps outside an app bundle (the snapshot tests),
        // and the browsers' grants there would be this Mac's, not the references'.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        automation = PermissionFacts.automation(await PermissionFacts.readAutomation())
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = switch settings.authorizationStatus {
        case .authorized, .provisional: .allowed
        case .notDetermined: .notAsked
        default: .refused
        }
    }

    private func row(_ label: String, _ row: PermissionFacts.Row, pane: String,
                     ask: (() async -> Void)? = nil, check: (() async -> Void)? = nil) -> some View {
        self.row(label, row, url: OpenSystemSettingsButton.privacy(pane), ask: ask, check: check)
    }

    /// `ask`: macOS can prompt for this grant itself; the prompt comes from a
    /// click on Allow, never from opening the screen.
    private func row(_ label: String, _ row: PermissionFacts.Row, url: String,
                     ask: (() async -> Void)? = nil, check: (() async -> Void)? = nil) -> some View {
        let mark = PermissionFacts.mark(row.grant)
        let tint: Color = switch mark {
        case .allowed: Color.Vedivox.success
        case .refused: Color.Vedivox.danger
        case .neutral: Color.Vedivox.fgSecondary
        }
        return SettingsRow(label: label, caption: row.caption) {
            HStack(spacing: VedivoxSpace.m) {
                Image(systemName: mark.symbol)
                    .foregroundStyle(tint)
                    .help(mark.help)
                // The widest button holds the column, so the marks line up whatever the row's button.
                ZStack(alignment: .trailing) {
                    OpenSystemSettingsButton(url: url).hidden()
                    switch PermissionFacts.action(row.grant, canAsk: ask != nil, canCheck: check != nil) {
                    case .ask:
                        Button("Allow") { Task { await ask?(); await refresh() } }
                            .buttonStyle(.vedivoxGhost)
                    case .check:
                        Button(checkingSystemAudio ? "Checking…" : "Check") {
                            checkingSystemAudio = true
                            Task {
                                await check?()
                                checkingSystemAudio = false
                                await refresh()
                            }
                        }
                        .buttonStyle(.vedivoxGhost)
                        .disabled(checkingSystemAudio)
                    case .openSettings:
                        OpenSystemSettingsButton(url: url)
                    }
                }
            }
        }
    }
}

// MARK: - About

private struct AboutSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage(UpdateChecker.enabledKey) private var checkForUpdates = true

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var updateStatus: (label: String, caption: String?) {
        let checker = appState.updateChecker
        if let release = checker.available { return ("Vedivox \(release.version) is available", "brew upgrade or the release page") }
        let last = (UserDefaults.standard.object(forKey: UpdateChecker.lastCheckKey) as? Date)
            .map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))" }
        switch checker.status {
        case .checking: return ("Checking\u{2026}", last)
        case .failed: return ("Could not reach GitHub", last)
        case .upToDate: return ("Vedivox is up to date", last)
        case .idle: return (last == nil ? "Not checked yet" : "No newer version found", last)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Vedivox") {
                SettingsRow(label: "Version", caption: "A local meeting recorder and dictation: transcription and speaker recognition, all on this Mac.") {
                    Text("\(version) (\(build))")
                        .vedivoxFont(.timecode)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }
                SettingsRow(
                    label: "Check for updates",
                    caption: "Once a day Vedivox asks GitHub for the latest release. Nothing else is sent, and nothing is installed."
                ) {
                    Toggle("", isOn: $checkForUpdates).toggleStyle(.switch)
                }
                SettingsRow(label: updateStatus.label, caption: updateStatus.caption) {
                    if let release = appState.updateChecker.available {
                        Button("Show") { showUpdateWindow(release) }
                    } else {
                        Button("Check Now") { Task { await appState.updateChecker.check() } }
                            .disabled(appState.updateChecker.status == .checking)
                    }
                }
                SettingsRow(label: "Source code", caption: "Free and open source. A star helps others find it.") {
                    Button("Star on GitHub") { NSWorkspace.shared.open(VedivoxLinks.repository) }
                }
            }

            SettingsGroup(title: "Under the hood") {
                shortcutText("FluidAudio — Parakeet speech recognition, diarization and speaker embeddings on the Neural Engine")
                shortcutText("GRDB — SQLite storage")
                shortcutText("KeyboardShortcuts — global hotkeys")
            }
        }
    }

    private func shortcutText(_ text: String) -> some View {
        Text(text)
            .vedivoxFont(.caption)
            .foregroundStyle(Color.Vedivox.fgSecondary)
    }
}
