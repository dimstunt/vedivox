import AppKit
import Foundation
import KeyboardShortcuts
import SwiftUI

@MainActor
@Observable
final class AppState {
    enum SidebarView: String, CaseIterable, Identifiable {
        case meetings, speakers, listen, series, dictations, settings
        var id: String { rawValue }
    }

    var meetings: [Meeting] = []
    var selectedMeetingIds: Set<String> = []

    /// The last sidebar meeting click, used to measure click→render latency.
    /// With its meeting: a switch made by Listen, a link or a reprocess was
    /// measured from a click minutes old.
    var lastMeetingClick: (id: String, at: CFAbsoluteTime)?

    /// Single selected meeting ID (for detail pane). Returns ID only when exactly one meeting is selected.
    var selectedMeetingId: String? {
        get { selectedMeetingIds.count == 1 ? selectedMeetingIds.first : nil }
        set {
            if let id = newValue {
                selectedMeetingIds = [id]
            } else {
                selectedMeetingIds = []
            }
        }
    }

    /// True only while a warm-up has been running longer than
    /// `modelLoadRevealDelay` — not «a warm-up is in flight». Warm-up runs on
    /// every launch and finishes in fractions of a second on cached models, so
    /// this stays false there and the banner never flashes.
    var isModelLoading = false
    var modelLoadError: String?
    /// A refused Edit → Undo of a speaker change, shown by the main window: the
    /// screen that registered the undo is usually gone by the time ⌘Z is pressed.
    var speakerUndoFailure: String?
    /// Why processing of a meeting failed in this run, by meeting id — what
    /// its error screen names. Not stored: after a relaunch the
    /// screen points at the log.
    var processingFailureReasons: [String: String] = [:]
    /// The «not processed» banner's state: here, so it outlives the window.
    let failedMeetingsOffer = FailedMeetingsOffer()
    /// Live download/compile progress during model warm-up, surfaced by the
    /// loading banner. nil when no warm-up is in flight; reports
    /// arriving after their run ended are dropped, so it does not linger.
    var modelLoadProgress: ModelLoadProgress?

    /// The database is being copied and migrated after an update, and has been
    /// for long enough to be worth saying. Until it is done every query waits:
    /// the window says so instead of showing an empty library.
    var libraryUpdate: LibraryUpdate?
    /// The phase as reported, before the reveal delay — see `followLibraryUpdate`.
    @ObservationIgnored private var reportedLibraryUpdate: LibraryUpdate?

    /// First-launch onboarding gate. True until the user finishes
    /// the welcome wizard; while true, meeting detection (and its Apple Events /
    /// notification prompts) is held back so the first launch isn't a wall of
    /// unexpected TCC dialogs.
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingCompleted")
    /// Incremented after transcription completes to trigger UI refresh
    var transcriptVersion: Int = 0
    /// Pending seek time from URL scheme (vedivox://meeting/{id}?t=seconds)
    var pendingSeekTime: Double?
    /// Screen state that survives leaving the screen, for this session only
    /// (screen-state-memory): where each meeting's player stood,
    /// the selected speaker, the settings section. Positions are read only
    /// at load time, so they need no observation.
    @ObservationIgnored var meetingPlaybackPositions: [String: TimeInterval] = [:]
    var selectedSpeakerId: String?
    var selectedSeriesId: String?
    /// What Speakers and Series loaded last: a return draws them in its first
    /// frame and reloads behind them, as Listen does. They used to open on
    /// "No Speakers" until the database answered (up to 0.5 s behind other
    /// reads), then build the whole screen again. nil — never loaded.
    var speakerInfos: [SpeakerInfo]?
    var speakerMeetings: (speakerId: String, meetings: [Meeting], coSpeakers: SpeakerChipFilter)?
    var seriesInfos: [SeriesInfo]?
    var seriesDetail: (seriesId: String, meetings: [Meeting], chips: SpeakerChipFilter)?
    var settingsSection: SettingsView.Section = .general
    /// Bumped by Settings → Shortcuts on every change. `shortcut(_:)` reads it,
    /// so menus and views showing a reassignable shortcut redraw.
    var shortcutsRevision = 0

    /// The user's current shortcut for a window command; nil when cleared.
    func shortcut(_ name: KeyboardShortcuts.Name) -> KeyboardShortcut? {
        _ = shortcutsRevision
        return KeyboardShortcuts.getShortcut(for: name)?.toSwiftUI
    }

    /// The same, as menu text (`⌘⇧1`) for tooltips; nil when cleared.
    func shortcutText(_ name: KeyboardShortcuts.Name) -> String? {
        _ = shortcutsRevision
        return KeyboardShortcuts.getShortcut(for: name)?.description
    }

    /// Sidebar context-menu «Переименовать»: the transcript header of this
    /// meeting picks the request up and enters title-edit mode.
    var renameRequestMeetingId: String?
    /// Sidebar context-menu «Настройки встречи…» → MeetingEditSheet.
    var meetingEditRequestId: String?
    /// Set once a dictation lost its text to the clipboard for lack of
    /// Accessibility permission. Drives a persistent banner: the system prompt
    /// appears only once per app, so after that the only route is System Settings
    /// and the user needs to be told which pane.
    var dictationNeedsAccessibility = false
    /// Meetings awaiting delete confirmation. Empty means no pending
    /// request; setting it is what raises the confirmation dialog owned by
    /// ContentView. Every delete entry point funnels through here, so the
    /// confirmation cannot be lost by reworking a single view again.
    var pendingDeleteIds: Set<String> = []

    var view: SidebarView = .meetings {
        didSet { if view != oldValue { screenOpen = ScreenOpenTrace("\(view)") } }
    }

    /// The opening of the section `view` names, timed from the click; the
    /// screen marks its own steps on it.
    @ObservationIgnored private(set) var screenOpen: ScreenOpenTrace?

    /// Set by the main window's content: reopens the window after the user
    /// closed it (the app keeps running in the menu bar).
    var openMainWindow: (@MainActor () -> Void)?

    /// ⌘, and the menu bar's "Open Vedivox" land here: the main window comes
    /// forward, or is reopened when closed — never a second one.
    func showMainWindow(settings: Bool = false) {
        if settings { view = .settings }
        // By the scene id SwiftUI stamps on the window: a minimized window
        // answers canBecomeMain = false, and a closed one lingers invisible.
        let mainWindow = NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix("main-") == true && ($0.isVisible || $0.isMiniaturized)
        }
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    var meetingSeries: [MeetingSeries] = []
    /// Dictation history, newest first. Loaded when the tab is opened and after
    /// each dictation — small enough that paging would be premature.
    var dictations: [Dictation] = []
    /// All dictations, not only the loaded page — the sidebar badge (#3).
    var dictationTotal: Int?
    /// Sidebar meeting filter: show only meetings that include ALL of these
    /// speakers. Lives here (not in SidebarView) so the Speakers page can set
    /// it via «Показать встречи».
    var sidebarSpeakerFilterIds: Set<String> = []

    // MARK: - Navigation History

    enum NavigationDestination: Equatable {
        case meeting(String)
        case speakers
        case listen
        case series
        case dictations
        case settings
    }

    private(set) var navigationHistory: [NavigationDestination] = []
    private(set) var historyIndex: Int = -1

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < navigationHistory.count - 1 }

    func pushNavigation(_ destination: NavigationDestination) {
        // Skip duplicate of current position
        if historyIndex >= 0, historyIndex < navigationHistory.count,
           navigationHistory[historyIndex] == destination { return }
        // Trim forward history
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
        }
        navigationHistory.append(destination)
        historyIndex = navigationHistory.count - 1
    }

    func navigateBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        applyDestination(navigationHistory[historyIndex])
    }

    func navigateForward() {
        guard canGoForward else { return }
        historyIndex += 1
        applyDestination(navigationHistory[historyIndex])
    }

    private func applyDestination(_ dest: NavigationDestination) {
        switch dest {
        case .meeting(let id):
            selectedMeetingId = id
            view = .meetings
        case .speakers: view = .speakers
        case .listen: view = .listen
        case .series: view = .series
        case .dictations: view = .dictations
        case .settings: view = .settings
        }
    }

    private let meetingRepo = MeetingRepository()
    private let seriesRepo = SeriesRepository()
    private let dictationRepo = DictationRepository()
    let pipeline = TranscriptionPipeline()

    // Phase 3: Detection services
    let calendarService = CalendarService()
    let meetingDetector: MeetingDetector
    let notificationService = NotificationService()
    let menuBarController = MenuBarController()
    let updateChecker = UpdateChecker()

    /// System-wide dictation (⌥Space). Shares the pipeline so the ASR model is
    /// loaded once for both meetings and dictation.
    ///
    /// `@ObservationIgnored` because nothing in the UI observes it — the
    /// controller pushes its state to the menu bar directly — and the
    /// `@Observable` macro cannot wrap a `lazy` stored property.
    @ObservationIgnored let dictationController: DictationController
    /// Mic speech up to here was dictation: it does not hold a meeting's auto stop.
    @ObservationIgnored private var lastDictationEndAt: Date?

    /// Floating recording indicator for dictation. Owned here because dictation
    /// runs with the main window closed, so nothing in the view hierarchy is
    /// guaranteed to be alive to own it.
    @ObservationIgnored private let dictationHUD = DictationHUDController()

    /// Guards start/stopDetection: both are reachable from launch, onboarding
    /// completion, and the Settings toggle — the monitors must not double-start.
    private var detectionRunning = false
    let processMonitor = ProcessMonitor()
    let recordingVM = RecordingViewModel()

    /// The most recent detected meeting (nil if none or dismissed).
    var detectedMeeting: DetectedMeetingInfo?

    /// Background safety net — runs at most once per hour, surfaces
    /// canonical-embedding collisions among confirmed enrolled speakers in the log.
    private let driftMonitor = SpeakerDriftMonitor()

    /// Recording-time «не в транскрипт» toggle (transcript-exclusion-marks, D6).
    let exclusionToggle = ExclusionToggle()

    /// Hides mic speech said while muted in Zoom (zoom-mute-exclusion).
    let muteMonitor = MuteMonitor()

    /// Bumped when the user asks for the meeting search (⌘F).
    ///
    /// A token rather than a call because the two ends cannot reach each other:
    /// the shortcut has to be a menu item (NSMenu resolves key equivalents
    /// before the first responder sees the event, so a hidden button in the
    /// view tree loses), and the focus state it needs to move is `@FocusState`
    /// private to `ContentView`.
    var focusSearchRequest = 0
    /// Bumped by Edit → Reveal in Sidebar, a token for the same reason; the sidebar scrolls to the open meeting.
    var revealInSidebarRequest = 0
    /// The ⌘K palette is open; the menu command toggles it, ContentView presents it.
    var commandPaletteOpen = false

    private var commandServer: CommandServer?

    @ObservationIgnored private var launchTasksClaimed = false

    /// When this process started: an unfinished meeting created after it is
    /// this run's own work, not a crash to recover from.
    @ObservationIgnored private let launchedAt = Date()

    /// Meetings with a reprocess running — see `reprocessMeeting`.
    @ObservationIgnored private var reprocessing: Set<String> = []

    /// True on the first call only: the launch sequence in `VedivoxApp` runs once
    /// per process, however many times the main window appears.
    func claimLaunchTasks() -> Bool {
        defer { launchTasksClaimed = true }
        return !launchTasksClaimed
    }

    init() {
        // Before the window reads the palette (VedivoxApp's @AppStorage).
        PreviousDefaults.pinIfNeeded(legacy: UserDefaults.standard.persistentDomain(forName: LegacyNames.bundleIdentifier))
        AppShortcuts.migrateLegacyRateKeys()
        Self.logBuild()
        self.meetingDetector = MeetingDetector(calendarService: calendarService)
        self.dictationController = DictationController(pipeline: pipeline)
        followLibraryUpdate()
        scheduleDriftCheck()
        // A merge stopped midway is rolled back or finished first (cli-meeting-edit):
        // its journal decides, and the pruning must not race it.
        // The edit lock starts taken (`MeetingEditLock.busy`) and is let go here.
        let meetings = meetingRepo
        Task.detached(priority: .background) {
            await meetings.recoverInterruptedMerges()
            await MainActor.run { self.meetingEdit.end() }
            UndoCopyRetention.pruneExpired()
        }
        setUpDictation()
    }

    /// Marks the start of a run in the log, with the build that is running.
    ///
    /// Until this the log had no launch marker at all, so "is the app running
    /// the build I just installed?" was unanswerable from the log — and after a
    /// `make install` that question decides whether a manual check means
    /// anything. `AppState` is created once per process, so this is one line per
    /// run; the build number comes from `git rev-list --count HEAD` at install
    /// time, which makes it directly comparable with the repository.
    private static func logBuild() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        Log.info("Vedivox \(version) (build \(build)) starting")
    }

    /// Wires the dictation hotkey and mirrors its state into the menu bar.
    ///
    /// While a meeting is being recorded the menu bar belongs to that recording,
    /// so dictation status is not allowed to overwrite it.
    private func setUpDictation() {
        dictationController.onStateChange = { [weak self] state in
            guard let self else { return }

            // The HUD tracks the recording itself and is independent of the menu
            // bar, which a meeting recording is allowed to own. It goes away when
            // recording ends — including on the way into .processing.
            // A finished dictation is already in history when the state returns
            // to idle, but the list re-reads only on appear — a Dictations tab
            // left open kept showing the old list (seen 2026-09-01).
            if case .idle = state { Task { await self.loadDictations() } }
            if state == .processing || state == .idle { self.lastDictationEndAt = Date() }

            switch state {
            case .starting: dictationHUD.show()
            // Already up since .starting: showing it again restarted the clock and
            // wiped the Escape warning raised in between.
            case .recording: break
            case .idle, .processing: dictationHUD.hide()
            }

            if case .recording = menuBarController.state { return }
            switch state {
            case .idle: menuBarController.updateState(.idle)
            case .starting, .recording: menuBarController.updateState(.dictating(isProcessing: false))
            case .processing: menuBarController.updateState(.dictating(isProcessing: true))
            }
        }
        dictationController.onFinished = { [weak self] start, end, text in
            self?.markDictation(start: start, end: end, text: text)
        }
        dictationController.onNotice = { [weak self] notice in
            guard let self else { return }
            switch notice {
            case .insertionFailed(let reason, let textInClipboard):
                // Usually recoverable — the text exists and is on the clipboard,
                // so the notification says how to get it. The exception is a
                // failed clipboard write, where "press ⌘V" would paste whatever
                // the user had there before.
                notificationService.notifyDictationFailed(
                    reason: reason, textInClipboard: textInClipboard
                )
            case .nothingRecognized:
                notificationService.notifyDictationFailed(
                    reason: "Nothing recognized", textInClipboard: false
                )
            case .recordingFailed:
                notificationService.notifyDictationFailed(
                    reason: "Could not start recording", textInClipboard: false
                )
            case .transcriptionFailed:
                notificationService.notifyDictationFailed(
                    reason: "Could not transcribe", textInClipboard: false
                )
            case .cancelled:
                // Deliberately silent: the user cancelled, they know. The HUD
                // vanishing is the whole confirmation needed.
                Log.info("Dictation cancelled by user")
            }
        }
        dictationController.onLiveDraft = { [weak self] draft in
            self?.dictationHUD.update(draft: draft)
        }
        dictationController.onLevel = { [weak self] level in
            self?.dictationHUD.update(level: level)
        }
        dictationController.onLiveState = { [weak self] state in
            // The HUD is the only channel that reaches the user mid-dictation:
            // the main-window banner is invisible with the window closed, a
            // mistake this project has already made twice.
            switch state {
            case .ready, .idle:
                self?.dictationHUD.update(status: nil)
            case .downloading(let fraction):
                let percent = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                self?.dictationHUD.update(status: "Loading live-text model…\(percent)")
            case .unavailable(let reason):
                self?.dictationHUD.update(status: reason)
            }
        }
        dictationController.onEscapePassesThrough = { [weak self] in
            self?.dictationHUD.update(warning: "Escape also reaches the app — allow Vedivox in Accessibility")
        }
        dictationController.onNeedsAccessibility = { [weak self] in
            self?.dictationNeedsAccessibility = true
        }
        dictationController.backgroundAudio.isRecordingMeeting = { [weak self] in
            self?.recordingVM.isRecording ?? false
        }
        // A Vedivox that died mid-dictation in «Mute sound» mode must not leave the
        // Mac silent: undo a leftover mute now, and on the way out.
        OutputMute.restore()
        NotificationCenter.default.addObserver(
            // nil queue: run synchronously on the posting thread, before exit.
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in OutputMute.restore() }
        leftoverDictationClips = DictationController.leftoverClips()
        dictationController.registerHotkey()
    }

    /// Found before the hotkey could start a new dictation; adopted at launch.
    @ObservationIgnored private var leftoverDictationClips: [URL] = []

    /// Dictations a quit or a crash cut short: leftover clips go to
    /// history, then everything owed a recognition gets it. Nothing is
    /// inserted — the field they were meant for is long gone. A failure leaves
    /// the entry awaiting, with Re-transcribe on it.
    func recoverInterruptedDictations() async {
        await dictationController.adopt(leftoverDictationClips)
        leftoverDictationClips = []
        let owed = (try? await dictationRepo.awaitingTranscription()) ?? []
        for dictation in owed {
            Log.info("Dictation \(dictation.id): recognizing what the last run left")
            await retranscribeDictation(dictation)
        }
        await loadDictations()
    }

    // MARK: - Dictation history

    func loadDictations() async {
        do {
            dictations = try await dictationRepo.recent()
            dictationTotal = try await dictationRepo.count()
        } catch {
            Log.error("Could not load dictation history: \(error.localizedDescription)")
        }
    }

    func copyDictationText(_ dictation: Dictation) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(dictation.text, forType: .string)
    }

    func deleteDictation(_ dictation: Dictation) async {
        do {
            try await dictationRepo.delete(dictation.id)
            await loadDictations()
        } catch {
            Log.error("Could not delete dictation: \(error.localizedDescription)")
        }
    }

    /// What a re-transcription did, so the interface can say it.
    ///
    /// Three cases and not two: re-running the same model over the same audio
    /// usually produces **the same text**, so «nothing visibly happened» is the
    /// normal outcome, not the failure. Collapsing it into «done» leaves the
    /// user exactly where they were before — pressing a button and guessing.
    enum RetranscribeOutcome {
        case replaced
        case unchanged
        case failed
    }

    /// Re-runs recognition over the stored audio and replaces the text.
    ///
    /// Only offered while the audio exists — retention drops audio long before
    /// it drops text, so most old entries can never be redone.
    @discardableResult
    func retranscribeDictation(_ dictation: Dictation) async -> RetranscribeOutcome {
        guard let audioURL = dictationRepo.audioURL(for: dictation),
              FileManager.default.fileExists(atPath: audioURL.path)
        else {
            Log.info("Dictation \(dictation.id): no audio to re-transcribe")
            return .failed
        }

        do {
            let converted = audioURL.deletingPathExtension().appendingPathExtension("16k.wav")
            try await AudioConverter.convertTo16kHzMonoWAV(input: audioURL, output: converted)
            defer { try? FileManager.default.removeItem(at: converted) }

            let text = try await pipeline.transcribeDictation(converted)
            guard !text.isEmpty else {
                Log.info("Dictation \(dictation.id): re-transcription produced nothing, keeping the old text")
                if dictation.awaitingTranscription {
                    try await dictationRepo.updateText(dictation.id, text: "")
                    await loadDictations()
                }
                return .unchanged
            }
            guard text != dictation.text else {
                Log.info("Dictation \(dictation.id): re-transcription produced the same text")
                return .unchanged
            }
            try await dictationRepo.updateText(dictation.id, text: text)
            await loadDictations()
            return .replaced
        } catch {
            Log.error("Could not re-transcribe dictation: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Kick the drift monitor off the MainActor — non-blocking, throttled.
    private func scheduleDriftCheck() {
        Task.detached(priority: .background) { [driftMonitor] in
            do {
                _ = try await driftMonitor.runCheck()
            } catch {
                // Non-critical — failures here just mean we'll try again next launch.
                Log.error("DriftMonitor check failed: \(error.localizedDescription)")
            }
        }
    }

    /// Listen for distributed notifications from VedivoxMCP and reload data.
    var selectedMeeting: Meeting? {
        meetings.first { $0.id == selectedMeetingId }
    }

    /// Shows what `DatabaseSafety.update` reports. After the same delay as the
    /// model banner: a new install and a small library are done in a blink,
    /// and a banner that flashes reads as a glitch.
    private func followLibraryUpdate() {
        Task { [weak self] in
            for await phase in LibraryUpdate.phases {
                guard let self else { return }
                reportedLibraryUpdate = phase
                guard let phase else {
                    if libraryUpdate != nil { Log.info("Library update finished") }
                    libraryUpdate = nil
                    continue
                }
                if libraryUpdate != nil {
                    libraryUpdate = phase
                } else if phase == .backingUp {
                    Task { [weak self] in
                        try? await Task.sleep(for: Self.modelLoadRevealDelay)
                        guard let self, let current = reportedLibraryUpdate else { return }
                        Log.info("Library update is taking a while — showing it in the window")
                        libraryUpdate = current
                    }
                }
            }
        }
    }

    func loadMeetings() async {
        do {
            // Not the caller's to cancel: a window reopened during a slow
            // launch cancelled its own load, which then logged an error and
            // left the list as it was.
            let repo = meetingRepo
            meetings = try await uncancelled { try await repo.all() }
        } catch {
            Log.error("Failed to load meetings: \(error)")
        }
        listen.dataChanged()
    }

    // MARK: - Listen queue (listen-queue § 7)

    /// The Listen section's model. It outlives the section's view, so a
    /// return shows the last list at once, and it counts the sidebar badge:
    /// every meeting list reload — that is after a command and after
    /// processing too — tells it the data changed, and it answers a burst of
    /// them with one recount. `var` for the snapshot tests.
    var listen = ListenViewModel()
    /// Meeting the Listen section opens filtered to (the meeting header's
    /// «N voices to check»); consumed by the section on appear.
    var listenMeetingFilter: String?

    func openListen(meetingId: String?) {
        listenMeetingFilter = meetingId
        view = .listen
    }

    func loadSeries() async {
        meetingSeries = (try? await seriesRepo.all()) ?? []
    }

    /// Meetings a previous run left recording or processing. Asked once, right
    /// after the first load: later in the same run these statuses belong to
    /// live work — a recording started from the menu bar, its processing.
    func orphanedRecordings() -> [Meeting] {
        // The recording in progress is not an orphan (a command or the hotkey
        // can start one before this runs on a cold start); neither is anything
        // else this run started.
        let live = reprocessing.union([recordingVM.currentMeetingId].compactMap { $0 })
        let orphans = Meeting.orphans(among: meetings, launchedAt: launchedAt, live: live)
        Log.info("Found \(orphans.count) orphaned meetings")
        return orphans
    }

    /// Recover orphaned recordings (from crashes) — try to transcribe if audio exists.
    func recoverOrphanedRecordings(_ orphans: [Meeting]) async {
        guard !orphans.isEmpty else { return }

        // Collect audio paths of completed meetings to detect duplicates
        let donePaths = Set(
            meetings
                .filter { $0.status == .done }
                .compactMap { $0.micAudioPath }
        )

        for orphan in orphans {
            Log.info("Processing orphan \(orphan.id) (status: \(orphan.status.rawValue))")

            // Skip if another meeting already completed with the same audio
            if let path = orphan.micAudioPath, donePaths.contains(path) {
                Log.info("Duplicate of completed meeting, deleting orphan \(orphan.id)")
                try? await meetingRepo.delete(orphan.id)
                continue
            }

            let marker = RecoveryMarker()
            if marker.diedDuring(orphan.id) {
                Log.error("Recovery of \(orphan.id) did not finish last time, marking error (Reprocess is available)")
                try? await meetingRepo.updateStatus(
                    orphan.id, status: .error, reason: MeetingStatusReason.recoveryInterrupted.rawValue
                )
                continue
            }

            // An interrupted import starts again from the imported file while
            // it is still there: the mic.wav a cut-off extraction left is
            // short, and a video original is not something findMicAudio returns.
            let importOriginal = orphan.importedOriginal
            let micURL = importOriginal ?? findMicAudio(for: orphan)

            if let micURL {
                Log.info("Found audio at \(micURL.path), size OK")
                if importOriginal == nil {
                    var updated = orphan
                    updated.micAudioPath = micURL.path
                    try? await meetingRepo.save(updated)
                }

                // Segments saved before the interruption — a partial result,
                // or the previous transcript of an interrupted reprocess — stay
                // until the pipeline has new ones to replace them with. Leaving
                // the meeting alone was "in progress" forever, with Reprocess
                // and delete refused.
                do {
                    marker.begin(orphan.id)
                    defer { marker.end() }
                    // A crash or a quit mid-recording leaves BOTH tracks with a
                    // header that says "no audio": an unrepaired system.wav
                    // reads as empty and the other side of the call is gone
                    // from the transcript.
                    let systemURL = findSystemAudio(for: orphan)
                    for url in [micURL, systemURL].compactMap({ $0 })
                        where importOriginal == nil && url.pathExtension.lowercased() == "wav" {
                        do {
                            let repaired = try AudioConverter.repairWAVHeaderIfNeeded(url)
                            Log.info("\(url.lastPathComponent) repair needed: \(repaired ? "yes, fixed" : "no")")
                        } catch {
                            Log.error("\(url.lastPathComponent) repair failed: \(error.localizedDescription)")
                        }
                    }
                    // After the repair: an unrepaired header reads as an empty track.
                    if importOriginal == nil { await meetingRepo.fillMissingDuration(orphan.id, from: micURL) }

                    Log.info("Starting transcription for \(orphan.id) (system audio: \(systemURL != nil ? "yes" : "no"))")
                    do {
                        if orphan.source == .import {
                            // One file with everyone in it: through the recording
                            // path below all of it became the owner's speech.
                            try await pipeline.processImportedFile(meetingId: orphan.id, fileURL: micURL)
                        } else {
                            try await pipeline.processMeeting(
                                meetingId: orphan.id,
                                micAudioURL: micURL,
                                systemAudioURL: systemURL
                            )
                        }
                        self.transcriptVersion += 1
                        Log.info("Transcription succeeded for \(orphan.id)")
                    } catch {
                        Log.error("Transcription failed for \(orphan.id): \(error.localizedDescription)")
                        try? await self.meetingRepo.updateStatus(
                            orphan.id, status: .error
                        )
                    }
                }
            } else {
                Log.error("No audio for orphan \(orphan.id), marking error")
                try? await meetingRepo.updateStatus(orphan.id, status: .error, reason: MeetingStatusReason.noAudio.rawValue)
            }
        }

        await loadMeetings()
    }

    /// Find mic.wav file for a meeting, checking DB path, standard location, and sourceFilePath.
    private nonisolated func findMicAudio(for meeting: Meeting) -> URL? {
        // Check DB path first
        if let path = meeting.micAudioPath,
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if fileHasData(url) { return url }
        }

        // Check standard audio directory (.m4a first, then legacy .wav)
        guard let audioDir = try? DatabaseManager.audioDirectory(for: meeting.id) else {
            return nil
        }
        let micM4A = audioDir.appendingPathComponent("mic.m4a")
        if fileHasData(micM4A) { return micM4A }
        let micWAV = audioDir.appendingPathComponent("mic.wav")
        if fileHasData(micWAV) { return micWAV }

        // For imported meetings, fall back to sourceFilePath (original imported
        // file) — but only for plain audio: AVAudioFile leaks its fd on .mov
        // containers (see AudioConverter).
        if let path = meeting.sourceFilePath,
           AudioConverter.isSafeForDirectRead(URL(fileURLWithPath: path)),
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if fileHasData(url) { return url }
        }

        return nil
    }

    private nonisolated func findSystemAudio(for meeting: Meeting) -> URL? {
        if let path = meeting.systemAudioPath,
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if fileHasData(url) { return url }
        }

        guard let audioDir = try? DatabaseManager.audioDirectory(for: meeting.id) else {
            return nil
        }
        let systemM4A = audioDir.appendingPathComponent("system.m4a")
        if fileHasData(systemM4A) { return systemM4A }
        let systemWAV = audioDir.appendingPathComponent("system.wav")
        if fileHasData(systemWAV) { return systemWAV }

        return nil
    }

    private nonisolated func fileHasData(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return false }
        return size > 1000
    }

    // MARK: - Deletion

    /// Raise the delete confirmation. This is the ONLY method the UI may call —
    /// `performDeleteMeetings` deletes with no questions asked, so keeping it
    /// off the menus is what makes the confirmation unskippable.
    func requestDeleteMeetings(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        pendingDeleteIds = ids
    }

    func cancelPendingDelete() {
        pendingDeleteIds = []
    }

    /// Synchronous on purpose: dismissing the alert clears `pendingDeleteIds`,
    /// so the ids must be captured in the same turn as the button tap. Reading
    /// them inside a `Task` would race the dismissal and delete nothing.
    func confirmPendingDelete() {
        let ids = pendingDeleteIds
        pendingDeleteIds = []
        guard !ids.isEmpty else { return }
        Task {
            let deletable = await deletableNow(ids)
            guard !deletable.isEmpty else { return }
            await performDeleteMeetings(deletable)
        }
    }

    /// The ids without the meetings still being recorded or processed, which
    /// are named to the user. Such a meeting belongs to the recorder or the
    /// pipeline: deleting it moved the audio to the Trash under them and left
    /// the capture running with no meeting to stop. The command path refuses
    /// the whole batch itself; this is the window's path. Status straight from
    /// the database — the sidebar cache can be stale.
    private func deletableNow(_ ids: Set<String>) async -> Set<String> {
        var deletable = ids
        var busy: [String] = []
        for id in ids {
            if let meeting = try? await meetingRepo.find(id), meeting.status.isInProgress {
                busy.append(meeting.title)
                deletable.remove(id)
            }
        }
        if !busy.isEmpty {
            alertUser(
                "Still recording or processing — not deleted",
                busy.joined(separator: ", ") + ". Stop the recording or wait for processing to finish, then delete."
            )
        }
        return deletable
    }

    /// Title for the confirmation dialog: names the meeting when deleting one,
    /// counts them when deleting several.
    var pendingDeletePrompt: String {
        if pendingDeleteIds.count == 1, let id = pendingDeleteIds.first {
            let title = meetings.first { $0.id == id }?.title
            return "Delete meeting “\(title ?? id)”?"
        }
        return "Delete \(pendingDeleteIds.count) meetings?"
    }

    /// Returns whether the database rows went; the alert path ignores it, the
    /// `delete_meetings` command reports it.
    @discardableResult
    func performDeleteMeetings(_ ids: Set<String>) async -> Bool {
        do {
            // Rows first: a failed delete then leaves every meeting whole, and a
            // failed trash leaves only a stray audio folder, never a meeting without sound.
            try await meetingRepo.deleteBatch(ids)
            // Audio goes to the Trash, not into the void — see
            // DatabaseManager.trashAudioDirectory.
            for id in ids {
                do {
                    if let trashed = try DatabaseManager.trashAudioDirectory(for: id) {
                        Log.info("Deleted \(id): audio moved to Trash at \(trashed.path)")
                    }
                } catch {
                    Log.error("Failed to trash audio for \(id): \(error.localizedDescription)")
                }
            }
            meetings.removeAll { ids.contains($0.id) }

            // Clear selection if deleted meetings were selected
            selectedMeetingIds.subtract(ids)
            if selectedMeetingIds.isEmpty {
                selectedMeetingId = meetings.first?.id
            }
            return true
        } catch {
            Log.error("Failed to delete meetings: \(error)")
            return false
        }
    }

    func assignMeetingsToSeries(_ ids: Set<String>, seriesId: String) async {
        do {
            try await meetingRepo.assignSeriesToBatch(ids, seriesId: seriesId)
            // Update local state
            for i in meetings.indices where ids.contains(meetings[i].id) {
                meetings[i].seriesId = seriesId
            }
        } catch {
            Log.error("Failed to assign meetings to series: \(error)")
        }
    }

    func createSeriesAndAssignMeetings(_ ids: Set<String>, name: String) async {
        do {
            let (series, created) = try await seriesRepo.createOrReuse(MeetingSeries(name: name))
            if created {
                meetingSeries.append(series)
                meetingSeries.sort { $0.name < $1.name }
            }
            await assignMeetingsToSeries(ids, seriesId: series.id)
        } catch {
            Log.error("Failed to create series: \(error)")
        }
    }

    /// Canonical-collision pairs from the drift monitor.
    /// Throttled inside the actor; `force` recomputes after merges.
    func driftAlerts(force: Bool = false) async -> [SpeakerDriftMonitor.DriftAlert] {
        (try? await driftMonitor.runCheck(force: force)) ?? []
    }

    /// Assign a meeting to a series (nil removes it) and refresh the sidebar.
    func setMeetingSeries(_ meetingId: String, seriesId: String?) async {
        do {
            try await MeetingRepository().updateSeriesId(meetingId, seriesId: seriesId)
            await loadMeetings()
            transcriptVersion += 1
        } catch {
            Log.error("Failed to set series for \(meetingId): \(error)")
        }
    }

    /// Export any meeting's transcript to Markdown, loading segments from the
    /// repository — the meeting doesn't have to be open.
    @discardableResult
    func exportMeeting(_ meetingId: String) async -> AppCommandResponse {
        guard let meeting = await resolveMeeting(meetingId) else {
            let message = "Export: meeting \(meetingId) not found"
            Log.error(message)
            return .failure(message, reason: .notFound)
        }
        let segments = (try? await meetingRepo.segments(for: meetingId)) ?? []
        // The panel is modal: a socket caller waits for it, and learns what the user chose.
        do {
            guard let url = try TranscriptExporter.exportViaSavePanel(meeting: meeting, segments: segments) else {
                return .failure("Export of “\(meeting.title)” cancelled", reason: .failed)
            }
            return .success("Exported “\(meeting.title)” to \(url.path)")
        } catch {
            let message = "Export of “\(meeting.title)” failed: \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }
    }

    /// Finds a meeting for a command, without depending on the sidebar being
    /// loaded.
    ///
    /// `meetings` is a UI cache that is empty for the first seconds of a run.
    /// A command that arrives by URL launches the app, so it lands squarely in
    /// that window — which is how the 2026-08-14 reprocess request left no
    /// trace at all: the handler hit `guard let ... else { return }` before the
    /// list existed and returned as if it had done something.
    private func resolveMeeting(_ meetingId: String) async -> Meeting? {
        if let loaded = meetings.first(where: { $0.id == meetingId }) { return loaded }
        return try? await meetingRepo.find(meetingId)
    }

    /// Reprocess a meeting: delete old segments, re-run transcription + diarization pipeline.
    /// `suppressEcho`: true/false — explicit choice; nil — autodetect.
    @discardableResult
    func reprocessMeeting(
        _ meetingId: String, suppressEcho: Bool? = nil, discardingTranscript: Bool = false
    ) async -> AppCommandResponse {
        // Before the first await: the status check below sits several awaits
        // ahead of the status write, so two requests for one meeting (a double
        // click on Reprocess, the window and the CLI) both passed it and both
        // ran — every segment saved twice.
        guard !meetingEdit.meetingIds.contains(meetingId) else {
            let message = "Reprocess: meeting \(meetingId) is being split, trimmed or merged"
            Log.info(message)
            return .failure(message, reason: .notReady)
        }
        guard reprocessing.insert(meetingId).inserted else {
            let message = "Reprocess: meeting \(meetingId) is already being reprocessed"
            Log.info(message)
            return .failure(message, reason: .notReady)
        }
        defer { reprocessing.remove(meetingId) }

        guard let meeting = await resolveMeeting(meetingId) else {
            let message = "Reprocess: meeting \(meetingId) not found"
            Log.error(message)
            return .failure(message, reason: .notFound)
        }
        // Straight from the database: the sidebar cache can hold a stale
        // status. Reprocessing a live recording read a half-written file and
        // marked the meeting failed while it was still recording.
        let stored = (try? await meetingRepo.find(meetingId)) ?? meeting
        let status = stored.status
        guard !status.isInProgress else {
            let message = "Reprocess “\(meeting.title)”: meeting is \(status.rawValue); try again when it is done"
            Log.error(message)
            return .failure(message, reason: .notReady)
        }
        // An import that failed starts again from the imported file, like one
        // a crash interrupted: the mic.wav a failed extraction left is short,
        // and a run over it used to end by deleting the full file.
        guard let audioURL = meeting.importedOriginal ?? findMicAudio(for: meeting) else {
            let message = "Reprocess “\(meeting.title)”: no audio found"
            Log.error(message)
            return .failure(message, reason: .missingAudio)
        }

        // Snapshot this meeting's speakers BEFORE delete — their canonicals are
        // recalculated after the pipeline finishes (segments changed).
        let speakerRepo = SpeakerRepository()
        let oldSpeakers = (try? await speakerRepo.speakersForMeeting(meetingId)) ?? []

        // The old transcript goes only when a new one can be made: without
        // models (no network on a fresh machine) the pipeline fails at its
        // first step, and the meeting was left empty and failed, edits gone.
        do {
            try await pipeline.warmUp()
            // Loaded here, not by Retry: the failed-load banner is stale.
            modelLoadError = nil
        } catch {
            let message = "Reprocess “\(meeting.title)”: models are not available (\(error.localizedDescription)); the transcript is unchanged"
            Log.error(message)
            processingFailureReasons[meetingId] = "the speech models could not be loaded (\(error.localizedDescription))"
            return .failure(message, reason: .failed)
        }

        // The old transcript stays until the pipeline has a new one and swaps
        // them in one transaction (MeetingRepository.replaceSegments): deleted
        // up front, it was lost to any failure on the way — a track that would
        // not convert, a full disk — with every text edit and speaker made by
        // hand. What it was is kept to tell afterwards whether that happened.
        // The old transcript as it was, for the report of who moved where.
        let before = (try? await meetingRepo.segments(for: meetingId)) ?? []
        if discardingTranscript {
            try? await meetingRepo.deleteSegmentsAndSpeakers(for: meetingId)
        }
        let oldSegmentIds = discardingTranscript ? [] : before.compactMap(\.id)
        try? await meetingRepo.updateStatus(meetingId, status: .transcribing)

        await loadMeetings()
        transcriptVersion += 1

        // Re-run the appropriate pipeline based on meeting source.
        //
        // The outcome of *this* run is what gets reported. Reading the
        // meeting's status afterwards would answer a different question —
        // another reprocess of the same meeting could have moved it — and the
        // spec is explicit that the two must not be confused.
        var outcome: AppCommandResponse
        do {
            if meeting.source == .import {
                try await pipeline.processImportedFile(
                    meetingId: meetingId,
                    fileURL: audioURL
                )
            } else {
                let systemURL = findSystemAudio(for: meeting)
                try await pipeline.processMeeting(
                    meetingId: meetingId,
                    micAudioURL: audioURL,
                    systemAudioURL: systemURL,
                    suppressEcho: suppressEcho
                )
            }
            processingFailureReasons[meetingId] = nil
            Log.info("Reprocess succeeded for \(meetingId)")
            let newSpeakers = (try? await speakerRepo.speakersForMeeting(meetingId)) ?? []
            let names = Dictionary((oldSpeakers + newSpeakers).map { ($0.speaker.id, $0.speaker.displayName) }) { $1 }
            let after = (try? await meetingRepo.segments(for: meetingId)) ?? []
            Log.info("Reprocess report for \(meetingId): \(ReprocessReport(before: before, after: after, names: names).summary)")
            outcome = .success("Reprocess of “\(meeting.title)” finished")
        } catch {
            // Failed before the swap: the meeting is what it was, not a failed one.
            let segmentIds = ((try? await meetingRepo.segments(for: meetingId)) ?? []).compactMap(\.id)
            let unchanged = !oldSegmentIds.isEmpty && segmentIds == oldSegmentIds
            if unchanged {
                try? await meetingRepo.updateStatus(meetingId, status: status, reason: stored.statusReason)
            }
            if !unchanged { processingFailureReasons[meetingId] = error.localizedDescription }
            let message = "Reprocess of “\(meeting.title)” failed: \(error.localizedDescription)"
                + (unchanged ? "; the transcript is unchanged" : "")
            Log.error(message)
            outcome = .failure(message, reason: .failed)
        }
        // Either way: the open meeting's header shows processing until it reloads.
        transcriptVersion += 1

        // Recalculate embeddings for confirmed speakers that were in the old meeting
        // (their segments changed — old deleted, possibly new ones from diarization)
        // Not gated on the v1 column: v2-only speakers need it too, and a space
        // without voices is skipped by the recalc itself.
        for (speaker, _) in oldSpeakers where speaker.isConfirmed {
            try? await speakerRepo.recalculateEmbedding(speakerId: speaker.id, config: .automatic)
        }

        await loadMeetings()
        return outcome
    }

    /// Reprocess on the «not processed» banner.
    func reprocessFailedMeetings(_ failed: [Meeting]) async {
        await failedMeetingsOffer.run(
            failed.map(\.id),
            // From the database, like reprocessMeeting: the sidebar cache can be stale.
            stillFailed: { id in (try? await self.meetingRepo.find(id))?.status == .error },
            reprocess: { id in await self.reprocessMeeting(id) }
        )
    }

    // MARK: - Database Preflight

    /// Opens the database before anything else touches it.
    ///
    /// Returns the reason it cannot be used, or `nil` when it can. Doing this
    /// once and up front is what turns "the schema is newer than this build"
    /// into one sentence the user can act on, instead of a run where every
    /// query fails for reasons nobody reads.
    func preflightDatabase() async -> String? {
        do {
            _ = try await DatabaseManager.shared.db
            return nil
        } catch {
            let reason = String(describing: error)
            Log.error("AppState: database unusable — \(reason)")
            return reason
        }
    }

    // MARK: - External Commands

    /// Serves commands for the data directory this process holds.
    ///
    /// Only the lock holder listens, so "who executes a command" and "who owns
    /// the data" are the same question — which is what removes LaunchServices
    /// from the choice of recipient.
    func startCommandServer() {
        guard commandServer == nil else { return }
        guard DataDirectoryLock.current != nil else {
            Log.info("AppState: not the holder of \(DataDirectory.root.path) — not serving commands")
            return
        }

        let server = CommandServer(directory: DataDirectory.root) { [weak self] request in
            guard let self else {
                return .failure("The app is shutting down", reason: .notReady)
            }
            let response = await CommandDispatcher.dispatch(request, to: self)
            if CommandDispatcher.announcesRecordingStart(request, response) {
                await notificationService.notifyRecordingStartedFromCommandLine()
            }
            return response
        }

        do {
            try server.start()
            commandServer = server
        } catch {
            // Not fatal for the app, but fatal for every external tool: without
            // the socket they cannot reach this instance at all. It has to be
            // loud rather than a missing feature nobody notices.
            Log.error("AppState: command socket unavailable — \(error)")
        }
    }

    // MARK: - Split & Trim

    @ObservationIgnored private var meetingEdit = MeetingEditLock()
    private static let meetingEditBusyMessage =
        "Another split, trim or merge is running, or Vedivox is finishing an interrupted merge — try again in a moment"

    private func beginMeetingEdit(_ ids: String...) -> Bool { meetingEdit.begin(ids) }

    private func endMeetingEdit() { meetingEdit.end() }

    // Each button and its socket command (cli-meeting-edit) share one path:
    // the same repository call and the same refresh. The button adds only the
    // selection and the alert; the command adds the checks the window's
    // controls make (`MeetingEditCheck`) and an answer instead of an alert.

    private func performSplit(_ meetingId: String, atTime: Double) async throws -> (Meeting, Meeting) {
        let parts = try await meetingRepo.splitMeeting(meetingId, atTime: atTime)
        await loadMeetings()
        transcriptVersion += 1
        return parts
    }

    func splitMeeting(_ meetingId: String, atTime: Double) async {
        guard beginMeetingEdit(meetingId) else {
            return alertUser("Could not split the meeting", Self.meetingEditBusyMessage)
        }
        defer { endMeetingEdit() }
        do {
            let (_, meeting2) = try await performSplit(meetingId, atTime: atTime)
            selectedMeetingId = meeting2.id
        } catch {
            alertUser("Could not split the meeting", error.localizedDescription)
        }
    }

    private func performUndoSplit(_ meetingId: String) async throws {
        try await meetingRepo.undoSplit(meetingId)
        await loadMeetings()
        transcriptVersion += 1
    }

    func undoSplit(_ meetingId: String) async {
        guard beginMeetingEdit(meetingId) else {
            return alertUser("Could not undo the split", Self.meetingEditBusyMessage)
        }
        defer { endMeetingEdit() }
        // The second part is deleted by the undo: no reprocess may write into it meanwhile.
        if let parts = meetingRepo.splitParts(of: meetingId) { meetingEdit.add([parts.first, parts.second]) }
        do {
            try await performUndoSplit(meetingId)
        } catch {
            alertUser("Could not undo the split", error.localizedDescription)
        }
    }

    private func performTrim(_ meetingId: String, keepFrom: Double, keepTo: Double) async throws {
        try await meetingRepo.trimMeeting(meetingId, keepFrom: keepFrom, keepTo: keepTo)
        await loadMeetings()
        transcriptVersion += 1
    }

    func trimMeeting(_ meetingId: String, keepFrom: Double, keepTo: Double) async {
        guard beginMeetingEdit(meetingId) else {
            return alertUser("Could not trim the meeting", Self.meetingEditBusyMessage)
        }
        defer { endMeetingEdit() }
        do {
            try await performTrim(meetingId, keepFrom: keepFrom, keepTo: keepTo)
        } catch {
            alertUser("Could not trim the meeting", error.localizedDescription)
        }
    }

    /// Says why an action the user asked for in the window did not happen.
    /// A failed split, trim or merge used to be a line in the log: the user
    /// clicked, and nothing changed.
    private func alertUser(_ title: String, _ detail: String) {
        Log.error("\(title): \(detail)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    /// A merge takes seconds of audio work; with nothing on screen a second
    /// click ran it again and appended the later half's audio twice. Drives
    /// the top banner and disables the menu item.
    private(set) var mergeInProgress = false

    private func performMerge(_ id1: String, _ id2: String) async throws -> Meeting {
        mergeInProgress = true
        defer { mergeInProgress = false }
        let merged = try await meetingRepo.mergeMeetings(id1, id2)
        await loadMeetings()
        transcriptVersion += 1
        return merged
    }

    func mergeMeetings(_ id1: String, _ id2: String) async {
        guard beginMeetingEdit(id1, id2) else {
            return alertUser("Could not merge the meetings", Self.meetingEditBusyMessage)
        }
        defer { endMeetingEdit() }
        do {
            selectedMeetingId = try await performMerge(id1, id2).id
        } catch {
            alertUser("Could not merge the meetings", error.localizedDescription)
        }
    }

    private func performUndoMerge(_ meetingId: String) async throws {
        try await meetingRepo.undoMerge(meetingId)
        await loadMeetings()
        transcriptVersion += 1
    }

    func undoMerge(_ meetingId: String) async {
        guard beginMeetingEdit(meetingId) else {
            return alertUser("Could not undo the merge", Self.meetingEditBusyMessage)
        }
        defer { endMeetingEdit() }
        do {
            try await performUndoMerge(meetingId)
        } catch {
            alertUser("Could not undo the merge", error.localizedDescription)
        }
    }

    private struct ModelsUnavailable: LocalizedError {
        let underlying: Error
        var errorDescription: String? { "Models are not available: \(underlying.localizedDescription)" }
    }

    /// Restores the pre-trim audio; the caller reprocesses it once the edit lock is let go.
    private func performUndoTrim(_ meetingId: String) async throws {
        // The restored audio needs a new transcript: without models the old
        // one would stay over audio it no longer matches.
        do {
            try await pipeline.warmUp()
        } catch {
            throw ModelsUnavailable(underlying: error)
        }
        try await meetingRepo.undoTrim(meetingId)
    }

    /// Reprocess from restored audio; the transcript of the trimmed one is
    /// off against it by the trimmed start and is not worth keeping.
    private func reprocessAfterUndoTrim(_ meetingId: String) async -> AppCommandResponse {
        await reprocessMeeting(meetingId, discardingTranscript: true)
    }

    func undoTrim(_ meetingId: String) async {
        guard meetingRepo.canUndoTrim(meetingId) else { return }
        guard beginMeetingEdit(meetingId) else {
            return alertUser("Could not undo the trim", Self.meetingEditBusyMessage)
        }
        do {
            try await performUndoTrim(meetingId)
        } catch {
            endMeetingEdit()
            return alertUser("Could not undo the trim", error.localizedDescription)
        }
        endMeetingEdit()
        _ = await reprocessAfterUndoTrim(meetingId)
    }

    // MARK: - Split, trim, merge and undo from the command socket (cli-meeting-edit)

    /// The meeting as stored now, or why an edit of it is refused: the
    /// window's buttons are disabled while it is busy (`isBusy`).
    /// The meeting to edit, or the answer refusing it (`Result` needs an `Error`).
    private enum EditableMeeting {
        case success(Meeting)
        case failure(AppCommandResponse)
    }

    private func editableMeeting(_ id: String, command: String) async -> EditableMeeting {
        guard let meeting = try? await meetingRepo.find(id) else {
            return .failure(.failure("Meeting \(id) not found", reason: .notFound))
        }
        if meeting.status.isInProgress || reprocessing.contains(id) {
            let message = "Meeting “\(meeting.title)” (\(id)) is \(reprocessing.contains(id) ? "reprocessing" : meeting.status.rawValue); nothing changed"
            Log.error("\(command): \(message)")
            return .failure(.failure(message, reason: .notReady))
        }
        return .success(meeting)
    }

    private func spans(of meetingId: String) async -> [(start: Double, end: Double)] {
        ((try? await meetingRepo.segments(for: meetingId)) ?? []).map { ($0.startTime, $0.endTime) }
    }

    private func refused(_ command: String, _ message: String, _ reason: AppCommandResponse.Reason) -> AppCommandResponse {
        Log.error("\(command): \(message)")
        return .failure(message, reason: reason)
    }

    private func busyEdit(_ command: String) -> AppCommandResponse {
        refused(command, Self.meetingEditBusyMessage, .notReady)
    }

    /// The repository's refusals, as reasons a caller can act on.
    private func editFailure(_ command: String, _ what: String, _ error: Error) -> AppCommandResponse {
        let reason: AppCommandResponse.Reason = switch error as? MeetingRepository.SplitError {
        case .meetingBusy, .mergeUnfinished: .notReady
        case .noSplitInfo, .siblingNotFound, .meetingNotFound: .notFound
        default: .failed
        }
        return refused(command, "Could not \(what): \(error.localizedDescription)", reason)
    }

    func commandSplitMeeting(id: String, at time: Double) async -> AppCommandResponse {
        guard beginMeetingEdit(id) else { return busyEdit("split_meeting") }
        defer { endMeetingEdit() }
        let meeting: Meeting
        switch await editableMeeting(id, command: "split_meeting") {
        case .failure(let refusal): return refusal
        case .success(let found): meeting = found
        }
        if let why = MeetingEditCheck.split(at: time, duration: meeting.durationSeconds ?? 0, segments: await spans(of: id)) {
            return refused("split_meeting", "Cannot split “\(meeting.title)”: \(why)", .invalidParameters)
        }
        do {
            let (first, second) = try await performSplit(id, atTime: time)
            return .success(
                "Split “\(meeting.title)” at \(Int(time)) s → \(second.id)",
                data: ["meeting_ids": "\(first.id),\(second.id)"]
            )
        } catch {
            return editFailure("split_meeting", "split the meeting", error)
        }
    }

    func commandTrimMeeting(id: String, from: Double, to: Double) async -> AppCommandResponse {
        guard beginMeetingEdit(id) else { return busyEdit("trim_meeting") }
        defer { endMeetingEdit() }
        let meeting: Meeting
        switch await editableMeeting(id, command: "trim_meeting") {
        case .failure(let refusal): return refusal
        case .success(let found): meeting = found
        }
        let duration = meeting.durationSeconds ?? 0
        if let why = MeetingEditCheck.trim(from: from, to: to, duration: duration, segments: await spans(of: id)) {
            return refused("trim_meeting", "Cannot trim “\(meeting.title)”: \(why)", .invalidParameters)
        }
        do {
            try await performTrim(id, keepFrom: from, keepTo: to)
            return .success("Trimmed “\(meeting.title)” to \(Int(from))–\(Int(to)) s", data: ["meeting_id": id])
        } catch {
            return editFailure("trim_meeting", "trim the meeting", error)
        }
    }

    func commandMergeMeetings(firstId: String, secondId: String) async -> AppCommandResponse {
        guard beginMeetingEdit(firstId, secondId) else { return busyEdit("merge_meetings") }
        defer { endMeetingEdit() }
        for id in [firstId, secondId] {
            if case .failure(let refusal) = await editableMeeting(id, command: "merge_meetings") { return refusal }
        }
        do {
            let merged = try await performMerge(firstId, secondId)
            let absorbed = merged.id == firstId ? secondId : firstId
            return .success(
                "Merged into “\(merged.title)” (\(merged.id))",
                data: ["meeting_id": merged.id, "merged_id": absorbed]
            )
        } catch {
            return editFailure("merge_meetings", "merge the meetings", error)
        }
    }

    /// `kind` is split, trim or merge. A split is undone from either part.
    func commandUndoMeetingEdit(id: String, kind: String) async -> AppCommandResponse {
        let command = "undo_meeting_edit"
        guard beginMeetingEdit(id) else { return busyEdit(command) }
        var locked = true
        defer { if locked { endMeetingEdit() } }
        switch kind {
        case "split":
            guard let parts = meetingRepo.splitParts(of: id) else {
                return refused(command, "Meeting \(id) has no split to undo", .notFound)
            }
            meetingEdit.add([parts.first, parts.second])
            for part in [parts.first, parts.second] {
                if case .failure(let refusal) = await editableMeeting(part, command: command) { return refusal }
            }
            do {
                try await performUndoSplit(parts.first)
                return .success("Undid the split: \(parts.second) merged back into \(parts.first)",
                                data: ["meeting_ids": "\(parts.first),\(parts.second)"])
            } catch {
                return editFailure(command, "undo the split", error)
            }
        case "trim":
            guard meetingRepo.canUndoTrim(id) else { return refused(command, "Meeting \(id) has no trim to undo", .notFound) }
            if case .failure(let refusal) = await editableMeeting(id, command: command) { return refusal }
            do {
                try await performUndoTrim(id)
            } catch {
                return editFailure(command, "undo the trim", error)
            }
            // The audio is back; the reprocess runs outside the edit lock, as in the window.
            endMeetingEdit()
            locked = false
            return await reprocessAfterUndoTrim(id)
        case "merge":
            guard let restored = meetingRepo.mergedMeetingId(of: id) else {
                return refused(command, "Meeting \(id) has no merge to undo", .notFound)
            }
            meetingEdit.add([restored])
            if case .failure(let refusal) = await editableMeeting(id, command: command) { return refusal }
            do {
                try await performUndoMerge(id)
                return .success("Undid the merge: \(restored) restored", data: ["meeting_ids": "\(id),\(restored)"])
            } catch {
                return editFailure(command, "undo the merge", error)
            }
        default:
            return refused(command, "kind must be split, trim or merge", .invalidParameters)
        }
    }

    /// How long a warm-up may run before the loading banner is revealed.
    ///
    /// Warm-up is not a first-run event: `VedivoxApp` calls it on every launch, and
    /// the pipeline's `isModelLoaded` guard is an in-memory field that always
    /// starts false. On cached models the pass takes fractions of a second
    /// (measured: 0,29 s and 0,14 s for the diarizer), so revealing the banner
    /// immediately produced a flash that could not be read.
    private static let modelLoadRevealDelay = Duration.milliseconds(500)

    /// Guards progress state against reports that outlive the run producing
    /// them — see `WarmUpGeneration`.
    private var warmUpGeneration = WarmUpGeneration()

    func warmUpModel() async {
        let token = warmUpGeneration.begin()
        let startedAt = CFAbsoluteTimeGetCurrent()
        modelLoadError = nil
        modelLoadProgress = nil

        // Reveal the banner only if this run is still going after the delay.
        // Cancelled below, so a fast warm-up never flips the flag at all.
        let reveal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.modelLoadRevealDelay)
            guard !Task.isCancelled, let self, self.warmUpGeneration.accepts(token) else { return }
            Log.info("Warm-up #\(token) exceeded reveal delay — showing loading banner")
            self.isModelLoading = true
        }
        defer {
            reveal.cancel()
            // Only tear down state this run still owns: if a retry superseded
            // it, that retry owns the banner and must not be cleared here.
            let owned = warmUpGeneration.accepts(token)
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            Log.info(
                "Warm-up #\(token) finished in \(elapsedMs) ms "
                    + "(banner shown: \(isModelLoading), still current: \(owned))"
            )
            if owned {
                // Ends the run first — after this no in-flight report is
                // accepted, so the clears cannot be undone by a late arrival.
                warmUpGeneration.end(token)
                modelLoadProgress = nil
                isModelLoading = false
            }
        }

        do {
            try await pipeline.warmUp { [weak self] progress in
                // FluidAudio's progress handler fires on an unspecified queue;
                // hop to the main actor before touching @Observable state.
                Task { @MainActor in
                    guard let self, self.warmUpGeneration.accepts(token) else { return }
                    self.modelLoadProgress = progress
                }
            }
        } catch {
            Log.error("Model warm-up failed: \(error.localizedDescription)")
            if warmUpGeneration.accepts(token) {
                modelLoadError = error.localizedDescription
            }
        }
    }

    // MARK: - Series Batch Export

    /// Copy transcripts of the last N meetings in a series to clipboard as Markdown.
    func copySeriesTranscripts(seriesId: String, lastN: Int) async {
        let seriesMeetings = meetings
            .filter { $0.seriesId == seriesId && $0.status == .done }
            .prefix(lastN)

        var md = ""
        for meeting in seriesMeetings {
            let segments = (try? await meetingRepo.segments(for: meeting.id)) ?? []
            let speakerNames = Set(segments.compactMap(\.speakerLabel)).sorted()
            let durationStr: String = {
                guard let d = meeting.durationSeconds else { return "N/A" }
                return "\(Int(d) / 60)m \(Int(d) % 60)s"
            }()

            md += """
                # \(meeting.title)
                **Date:** \(meeting.startTime.formatted(date: .long, time: .shortened))
                **Duration:** \(durationStr)
                **Speakers:** \(speakerNames.joined(separator: ", "))

                ---


                """
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.drop(while: { $0 == " " }) }
                .joined(separator: "\n")

            for seg in segments {
                let label = seg.speakerLabel ?? "Speaker"
                md += "[\(seg.formattedTimeRange)] **\(label):** \(seg.text)\n\n"
            }
            md += "\n---\n\n"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    // MARK: - Phase 3: Detection

    func startDetection() async {
        // Opt-in: off unless turned on in onboarding or Settings.
        guard MeetingAutomation.isDetectionEnabled(), !detectionRunning else { return }
        detectionRunning = true

        await meetingDetector.setCallbacks(
            onDetected: { [weak self] detection in
                guard let self else { return }
                self.detectedMeeting = detection
                // A call (re)appeared — stop nagging about the previous one.
                self.notificationService.cancelMeetingEndedReminders()
                guard !self.recordingVM.isRecording else { return }
                let automation = MeetingAutomation.load()
                if automation.shouldAutoStart(
                    isRecording: false, lastManualStop: self.recordingVM.lastManualStopAt,
                    lastAutoStop: self.recordingVM.lastAutoStopAt, now: Date()
                ) {
                    if let stop = self.recordingVM.lastAutoStopAt, !automation.autoStart {
                        Log.info("Meeting detected: recording again — auto stop \(Int(Date().timeIntervalSince(stop))) s ago")
                    }
                    Task { await self.autoStartRecording(name: detection.displayName) }
                } else {
                    // Auto start on and not recording: only the manual-stop cooldown says no.
                    if automation.autoStart, let stop = self.recordingVM.lastManualStopAt {
                        Log.info("Meeting detected: auto start skipped — manual stop \(Int(Date().timeIntervalSince(stop))) s ago")
                    }
                    self.notificationService.notifyMeetingDetected(name: detection.displayName)
                    self.menuBarController.updateState(.meetingDetected(name: detection.displayName))
                }
            },
            onEnded: { [weak self] in
                guard let self else { return }
                self.detectedMeeting = nil
                if self.recordingVM.isRecording {
                    // Reminders (and the auto stop, when on) until the meeting
                    // comes back or the recording stops.
                    self.notificationService.startMeetingEndedReminders(
                        automation: MeetingAutomation.load(),
                        lastSpeech: { [weak self] in
                            guard let self else { return nil }
                            return MeetingAutomation.meetingSpeech(
                                lastMicSpeech: self.recordingVM.lastMicSpeechAt,
                                dictating: [.starting, .recording].contains(self.dictationController.state),
                                lastDictationEnd: self.lastDictationEndAt
                            )
                        },
                        onAutoStop: { [weak self] in
                            guard let self else { return }
                            Task {
                                if await self.recordingVM.stopRecording(appState: self, automatic: true) {
                                    Log.info("Meeting ended: recording stopped automatically")
                                    self.notificationService.notifyRecordingAutoStopped()
                                }
                            }
                        }
                    )
                } else {
                    // Nothing to stop — no notification (was the "stop when idle" bug).
                    self.menuBarController.updateState(.idle)
                }
            }
        )

        await applyDetectionConfig()

        // Start monitoring
        await meetingDetector.start(processMonitor: processMonitor)
    }

    /// Notifications are how Vedivox says what happened when no window is open: a
    /// dictation that was not inserted, a recording that did not start, the
    /// "not in transcript" toggle expiring. The permission used to be asked
    /// for only inside `startDetection`, which is off unless the user opts in
    /// — so on a default install none of those ever reached anyone.
    func enableNotifications() async {
        notificationService.setup()
        _ = await notificationService.requestPermission()
    }

    /// Auto start on a detected meeting, through the same path as
    /// the hotkey: title, calendar event and series come from the detection.
    private func autoStartRecording(name: String) async {
        let response = await commandStartRecording(title: nil)
        Log.info("Meeting detected: auto start → \(response.message)")
        if response.ok {
            notificationService.notifyRecordingAutoStarted(name: name)
        } else {
            notificationService.notifyRecordingFailed(reason: recordingFailureReason)
        }
    }

    /// Live counterpart of startDetection() for the Settings toggle: stop the
    /// monitors and reset detection-related UI state without an app relaunch.
    func stopDetection() async {
        guard detectionRunning else { return }
        detectionRunning = false
        await meetingDetector.stop()
        detectedMeeting = nil
        if !recordingVM.isRecording {
            menuBarController.updateState(.idle)
        }
    }

    /// Create the menu bar status item. Called unconditionally at launch:
    /// the icon is the recording indicator and the "Open Vedivox" entry, so it
    /// must not depend on meeting detection being enabled (it
    /// used to live behind the detection opt-in guard in startDetection()
    /// and vanished entirely when detection was off).
    func setupMenuBar() {
        // Menu bar — default to always visible (bool(forKey:) returns false for unset keys)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "menuBarAlwaysVisible") == nil {
            defaults.set(true, forKey: "menuBarAlwaysVisible")
        }
        menuBarController.alwaysVisible = defaults.bool(forKey: "menuBarAlwaysVisible")
        menuBarController.setup()
        menuBarController.onOpenApp = { [weak self] in
            self?.showMainWindow()
        }

        // Recording-time «не в транскрипт» toggle: menu item + global hotkey
        // drive the same path, the red icon mirrors the state, auto-expiry
        // surfaces as a notification (transcript-exclusion-marks, D6).
        menuBarController.onToggleExclusion = { [weak self] in
            self?.toggleExclusion()
        }
        exclusionToggle.onAutoExpire = { [weak self] in
            guard let self else { return }
            self.menuBarController.setExcluding(false)
            self.notificationService.notifyExclusionAutoExpired()
        }
        Self.migrateExclusionShortcutIfNeeded()
        KeyboardShortcuts.onKeyUp(for: .toggleExclusion) { [weak self] in
            self?.toggleExclusion()
        }
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleExclusion) {
            Log.info("Exclusion toggle: hotkey registered (\(shortcut))")
        } else {
            Log.info("Exclusion toggle: no hotkey assigned")
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.toggleRecording()
        }
        let recordingKey = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        Log.info("Recording toggle: hotkey registered (\(recordingKey?.description ?? "none"))")
    }

    /// A dictation made while a meeting records is not part of the meeting:
    /// its interval on the mic track goes out of the transcript, reversibly,
    /// and the transcript shows the dictated text in its place.
    /// ponytail: a meeting stopped mid-dictation gets no mark; track the last
    /// meeting's bounds if that turns up in practice.
    private func markDictation(start: Date, end: Date, text: String) {
        guard recordingVM.isRecording, let meetingId = recordingVM.currentMeetingId,
              let meetingStart = recordingVM.recordingStartTime else { return }
        let mark = MeetingMark(
            meetingId: meetingId,
            startTime: max(0, start.timeIntervalSince(meetingStart)),
            endTime: max(0, end.timeIntervalSince(meetingStart)),
            track: .mic, kind: .excluded, source: .dictation,
            text: text.isEmpty ? nil : text
        )
        Task {
            do { try await MarkRepository().add(mark) } catch {
                Log.error("Dictation mark for \(meetingId) not saved: \(error.localizedDescription)")
            }
        }
    }

    /// Global recording hotkey: start like the menu bar item, stop if
    /// recording. Goes through the CLI's start/stop, which already refuse a
    /// second start in flight and name the meeting after the detected one.
    /// Works during dictation too: the two use separate mic engines, and the
    /// extra ⌃ makes a slip from dictation's ⇧⌘2 unlikely.
    func toggleRecording() {
        Task {
            if recordingVM.isRecording {
                let response = await commandStopRecording()
                Log.info("Recording toggle: stop → \(response.message)")
            } else {
                let response = await commandStartRecording(title: nil)
                Log.info("Recording toggle: start → \(response.message)")
                if !response.ok { notificationService.notifyRecordingFailed(reason: recordingFailureReason) }
            }
        }
    }

    /// Builds 615–620 shipped ⌘⇧3 as the default — the macOS screenshot key —
    /// and KeyboardShortcuts **persists** the resolved shortcut to UserDefaults,
    /// so changing `default:` alone reaches nobody who launched those builds
    /// (same story as dictation's ⌥Space, see `migrateLegacyShortcutIfNeeded`).
    private static func migrateExclusionShortcutIfNeeded() {
        let flag = "exclusionShortcutMigratedFromCmdShift3"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        defer { UserDefaults.standard.set(true, forKey: flag) }

        let legacy = KeyboardShortcuts.Shortcut(.three, modifiers: [.command, .shift])
        guard KeyboardShortcuts.getShortcut(for: .toggleExclusion) == legacy else { return }

        KeyboardShortcuts.reset(.toggleExclusion)
        Log.info("Exclusion toggle: migrated hotkey off the screenshot-colliding ⌘⇧3 default")
    }

    /// Flips the «не в транскрипт» interval for the running recording. Outside
    /// a recording the toggle has nothing to act on — but a global hotkey that
    /// silently does nothing is indistinguishable from a broken one, so the
    /// no-op case says so in a notification instead of staying quiet.
    func toggleExclusion() {
        guard recordingVM.isRecording, let meetingId = recordingVM.currentMeetingId else {
            Log.info("Exclusion toggle: pressed with no active meeting recording — nothing to exclude")
            notificationService.notifyExclusionUnavailable()
            return
        }
        let elapsed = recordingVM.recordingDuration
        Log.info("Exclusion toggle: pressed at \(String(format: "%.1f", elapsed))s, meeting \(meetingId), active=\(exclusionToggle.isActive)")
        Task {
            await exclusionToggle.toggle(meetingId: meetingId, elapsed: elapsed)
            menuBarController.setExcluding(exclusionToggle.isActive)
        }
    }

    /// Finish first-launch onboarding: persist the detection choice, mark
    /// onboarding done, and start detection if the user opted in. Model warm-up
    /// already runs from launch, so it isn't re-triggered here.
    func completeOnboarding(enableDetection: Bool) async {
        UserDefaults.standard.set(enableDetection, forKey: MeetingAutomation.detectionEnabledKey)
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        showOnboarding = false
        await enableNotifications()
        if enableDetection {
            await startDetection()
        }
    }

    /// Pushes the per-app toggles and watched calendars to the detector. Called
    /// on start and from Settings, so a toggle applies without a relaunch; the
    /// detector reads it on its next poll.
    func applyDetectionConfig() async {
        // Build the set of enabled meeting app bundle IDs from user defaults.
        var enabledApps: Set<String> = []
        if UserDefaults.standard.object(forKey: "detectZoom") == nil
            || UserDefaults.standard.bool(forKey: "detectZoom")
        {
            enabledApps.insert("us.zoom.xos")
        }
        if UserDefaults.standard.object(forKey: "detectGoogleMeet") == nil
            || UserDefaults.standard.bool(forKey: "detectGoogleMeet")
        {
            enabledApps.insert(MeetingDetector.googleMeetId)
        }
        if UserDefaults.standard.object(forKey: "detectSlackHuddle") == nil
            || UserDefaults.standard.bool(forKey: "detectSlackHuddle")
        {
            enabledApps.insert("com.tinyspeck.slackmacgap")
        }
        if UserDefaults.standard.object(forKey: "detectTeams") == nil
            || UserDefaults.standard.bool(forKey: "detectTeams")
        {
            enabledApps.insert("com.microsoft.teams2")
        }
        // One toggle for the desktop app and the web client (telemost-support D3).
        // Off until switched on (#7): with it on, the browser tabs are polled
        // and Automation is asked even for someone who turned Google Meet off.
        if UserDefaults.standard.bool(forKey: "detectTelemost") {
            enabledApps.insert("ru.yandex.desktop.telemost")
            enabledApps.insert(WebMeetingService.telemost.id)
        }

        let calendars = Self.readWatchedCalendarIDs()
        let endThreshold = MeetingAutomation.load().detectorThreshold
        Log.info("Detection config: apps=\(enabledApps.sorted().joined(separator: ",")), watched calendars=\(calendars.count), end after \(Int(endThreshold)) s")
        await meetingDetector.updateConfig(
            enabledApps: enabledApps,
            watchedCalendarIDs: calendars,
            endThreshold: endThreshold
        )
    }

    private static func readWatchedCalendarIDs() -> [String] {
        guard let json = UserDefaults.standard.string(forKey: "watchedCalendarIDs"),
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }
}

// MARK: - CommandExecutor

/// The app's side of the command contract.
///
/// Thin on purpose: each case forwards to the method the UI already calls, so a
/// command and a menu item cannot drift into behaving differently.
extension AppState: CommandExecutor {
    func commandOpenMeeting(id: String, seekTime: Double?) async -> AppCommandResponse {
        guard let meeting = await resolveMeeting(id) else {
            let message = "Meeting \(id) not found"
            Log.error("open_meeting: \(message)")
            return .failure(message, reason: .notFound)
        }
        pendingSeekTime = seekTime
        selectedMeetingId = id
        NSApp.activate(ignoringOtherApps: true)
        return .success("Opened “\(meeting.title)”")
    }

    func commandReprocessMeeting(id: String, suppressEcho: Bool?) async -> AppCommandResponse {
        await reprocessMeeting(id, suppressEcho: suppressEcho)
    }

    func commandExportMeeting(id: String) async -> AppCommandResponse {
        await exportMeeting(id)
    }

    func commandImportFile(path: String, title: String?, date: String?) async -> AppCommandResponse {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            let message = "Import: file not found — \(path)"
            Log.error(message)
            return .failure(message, reason: .notFound)
        }

        // A date that cannot be read is refused rather than quietly replaced by
        // the file's creation date: the wrong day, reported nowhere, is how a
        // meeting ends up filed under the day it was imported.
        var startTime: Date?
        if let date {
            guard let parsed = ImportRequest.parseDate(date) else {
                let message = "Import: cannot read the date “\(date)” — use YYYY-MM-DD or ISO8601"
                Log.error(message)
                return .failure(message, reason: .invalidParameters)
            }
            startTime = parsed
        }

        do {
            let meetingId = try await FileImporter.importFile(
                url: url,
                title: title,
                startTime: startTime,
                appState: self,
                pipeline: pipeline
            )
            return .success("Imported \(url.lastPathComponent) (\(meetingId))")
        } catch {
            let message = "Import of \(url.lastPathComponent) failed: \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }
    }

    func commandTranscribeFile(path: String) async -> AppCommandResponse {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure("Transcribe: file not found — \(path)", reason: .notFound)
        }
        do {
            let segments = try await pipeline.transcribeTransient(fileURL: url)
            let rows = segments.map {
                ["speaker": $0.speakerLabel ?? "Unknown", "from": ($0.startTime * 100).rounded() / 100,
                 "to": ($0.endTime * 100).rounded() / 100, "text": $0.text] as [String: Any]
            }
            let json = try JSONSerialization.data(withJSONObject: rows)
            return .success(
                "Transcribed \(url.lastPathComponent): \(segments.count) segments",
                data: ["segments": String(bytes: json, encoding: .utf8) ?? "[]"]
            )
        } catch {
            let message = "Transcription of \(url.lastPathComponent) failed: \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }
    }
}

// MARK: - CommandExecutor: Data Changes

/// Changes requested from outside the app.
///
/// They run here, through the same repositories the UI uses, because the app is
/// the only writer. An external process writing to the database directly went
/// around this state — which is why the interface had to be told about its own
/// data changing by a distributed notification.
extension AppState {
    func commandUpdateSpeaker(id: String, fields: [String: String]) async -> AppCommandResponse {
        let repo = SpeakerRepository()
        guard var speaker = try? await repo.find(id) else {
            let message = "Speaker \(id) not found"
            Log.error("update_speaker: \(message)")
            return .failure(message, reason: .notFound)
        }

        var recalc: [EmbeddingSpace: SpeakerRepository.RecalcOutcome]?
        do {
            // "name" is the legacy spelling of nameEn and keeps its meaning:
            // it is the label written onto every segment of this speaker.
            let newNameEn = fields["name"] ?? fields["name_en"]
            if let newNameEn { speaker.nameEn = newNameEn }
            if let nickname = fields["nickname"] { speaker.nickname = nickname.isEmpty ? nil : nickname }
            if let nameRu = fields["name_ru"] { speaker.nameRu = nameRu.isEmpty ? nil : nameRu }
            try await repo.save(speaker)

            if let newNameEn, !newNameEn.isEmpty {
                try await repo.updateSegmentLabelsForSpeaker(id, newLabel: newNameEn)
            }

            if let isMe = fields["is_me"] {
                if isMe == "1" || isMe == "true" {
                    try await repo.markAsMe(id)
                } else {
                    speaker.isMe = false
                    try await repo.save(speaker)
                }
            }

            // Mirrors the UI rename flow: naming a person confirms the record
            // and rebuilds the canonical from their voices.
            if let confirmed = fields["confirmed"], confirmed == "1" || confirmed == "true" {
                try await repo.confirmSpeaker(id)
                recalc = try await repo.recalculateEmbedding(speakerId: id)
            }
        } catch {
            let message = "Could not update speaker \(id): \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }

        await refreshAfterExternalChange()
        let updated = "Updated speaker \(id): \(fields.keys.sorted().joined(separator: ", "))"
        return .success(recalc.map { "\(updated); \(SpeakerRepository.RecalcOutcome.summary($0))" } ?? updated)
    }

    func commandMergeSpeakers(targetId: String, sourceIds: [String]) async -> AppCommandResponse {
        let repo = SpeakerRepository()
        guard (try? await repo.find(targetId)) != nil else {
            let message = "Speaker \(targetId) not found"
            Log.error("merge_speakers: \(message)")
            return .failure(message, reason: .notFound)
        }

        let recalc: [EmbeddingSpace: SpeakerRepository.RecalcOutcome]
        do {
            recalc = try await repo.mergeSpeakers(targetId: targetId, sourceIds: sourceIds)
        } catch SpeakerRepository.MergeError.sourceNotFound(let id) {
            let message = "Speaker \(id) not found, nothing merged"
            Log.error("merge_speakers: \(message)")
            return .failure(message, reason: .notFound)
        } catch {
            let message = "Merge into \(targetId) failed: \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }

        await refreshAfterExternalChange()
        let canonical = recalc.isEmpty
            ? "canonical recalc failed, see log"
            : SpeakerRepository.RecalcOutcome.summary(recalc)
        return .success("Merged \(sourceIds.count) speaker(s) into \(targetId); \(canonical)")
    }

    func commandDetachMeetings(speakerId: String, meetingIds: [String]) async -> AppCommandResponse {
        let repo = SpeakerRepository()
        guard (try? await repo.find(speakerId)) != nil else {
            let message = "Speaker \(speakerId) not found"
            Log.error("detach_meetings: \(message)")
            return .failure(message, reason: .notFound)
        }

        let recalc: [EmbeddingSpace: SpeakerRepository.RecalcOutcome]
        do {
            recalc = try await repo.detachMeetings(speakerId: speakerId, meetingIds: meetingIds)
        } catch {
            let message = "Detach from \(speakerId) failed: \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }

        await refreshAfterExternalChange()
        return .success("Detached \(meetingIds.count) meeting(s) from \(speakerId); \(SpeakerRepository.RecalcOutcome.summary(recalc))")
    }

    func commandDeleteSpeaker(id: String) async -> AppCommandResponse {
        let meetings: Int
        do {
            meetings = try await SpeakerRepository().deleteSpeaker(id)
        } catch SpeakerRepository.DeleteError.notFound {
            return .failure("Speaker \(id) not found", reason: .notFound)
        } catch {
            let message = "Could not delete speaker \(id): \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }
        await refreshAfterExternalChange()
        return .success("Deleted speaker \(id); lines in \(meetings) meeting(s) are now unnamed")
    }

    func commandUpdateSegment(segmentId: Int64, speakerId: String) async -> AppCommandResponse {
        // Through the shared action: the move gets a verdict, links and a
        // canonical recalc, which 1633 calls on 2026-09-28 never did.
        let outcome: SpeakerVerdicts.AssignOutcome
        do {
            outcome = try await SpeakerVerdicts().assign(segmentId: segmentId, to: speakerId)
        } catch SpeakerVerdicts.VerdictError.speakerNotFound {
            let message = "Speaker \(speakerId) not found"
            Log.error("update_segment: \(message)")
            return .failure(message, reason: .notFound)
        } catch SpeakerVerdicts.VerdictError.noSegments {
            let message = "Segment \(segmentId) not found"
            Log.error("update_segment: \(message)")
            return .failure(message, reason: .notFound)
        } catch {
            let message = "Could not change the speaker on segment \(segmentId): \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }

        await refreshAfterExternalChange()
        return .success("Segment \(segmentId) → “\(outcome.speaker.nameEn)”; \(SpeakerRepository.RecalcOutcome.summary(outcome.target))")
    }

    func commandListen(_ request: AppCommandRequest) async -> AppCommandResponse {
        let response = await ListenCommands.handle(request)
        if response.ok, request.command != AppCommandName.listListenQueue {
            await refreshAfterExternalChange()
        }
        return response
    }

    func commandUpdateMeeting(id: String, fields: [String: String]) async -> AppCommandResponse {
        guard await resolveMeeting(id) != nil else {
            let message = "Meeting \(id) not found"
            Log.error("update_meeting: \(message)")
            return .failure(message, reason: .notFound)
        }

        do {
            if let title = fields["title"] { try await meetingRepo.updateTitle(id, title: title) }
            if let description = fields["description"] {
                try await meetingRepo.updateDescription(id, description: description.isEmpty ? nil : description)
            }
            if let seriesId = fields["series_id"] {
                try await meetingRepo.updateSeriesId(id, seriesId: seriesId.isEmpty ? nil : seriesId)
            }
        } catch {
            let message = "Could not update meeting \(id): \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }

        await refreshAfterExternalChange()
        return .success("Updated meeting \(id): \(fields.keys.sorted().joined(separator: ", "))")
    }

    /// The CLI's `vedivox meeting delete`: the same `performDeleteMeetings` the
    /// alert runs, behind the checks the alert gets from a human looking.
    func commandDeleteMeetings(ids: [String]) async -> AppCommandResponse {
        var found: [Meeting] = []
        for id in ids {
            // Straight from the database: the sidebar cache can hold a stale status.
            guard let meeting = try? await meetingRepo.find(id) else {
                let message = "Meeting \(id) not found"
                Log.error("delete_meetings: \(message)")
                return .failure(message, reason: .notFound)
            }
            found.append(meeting)
        }
        // A meeting still being written (recording) or processed would lose its
        // rows under the pipeline's feet; orphans from a crash are recovered at
        // launch, so an in-progress status in a running app is real.
        if let busy = found.first(where: { $0.status.isInProgress }) {
            let message = "Meeting “\(busy.title)” (\(busy.id)) is \(busy.status.rawValue); nothing deleted"
            Log.error("delete_meetings: \(message)")
            return .failure(message, reason: .notReady)
        }

        guard await performDeleteMeetings(Set(ids)) else {
            return .failure("Could not delete meetings: \(ids.joined(separator: ", ")) (see the log)", reason: .failed)
        }
        Log.info("delete_meetings: deleted \(ids.count) via command")
        return .success("Deleted \(ids.count) meeting(s)")
    }

    func commandStartRecording(title: String?) async -> AppCommandResponse {
        // Refuse while a start is in flight too (id still nil): answering with
        // whatever `currentMeetingId` holds later would report someone else's
        // meeting as ours.
        if recordingVM.isRecording {
            let message = recordingVM.currentMeetingId.map { "Already recording \($0)" } ?? "A recording is starting"
            return .failure(message, reason: .notReady)
        }
        // Without an explicit title, start like the menu does: name, calendar
        // event and series from the detected meeting.
        let detection = title == nil ? detectedMeeting : nil
        guard let id = await recordingVM.startRecording(
            title: title ?? detection?.displayName ?? "Recording",
            calendarEvent: detection?.calendarEvent,
            appState: self
        ) else {
            let message = "Recording did not start: \(recordingFailureReason)"
            Log.error("start_recording: \(message)")
            return .failure(message, reason: .failed)
        }
        let systemAudio = !recordingVM.systemAudioUnavailable
        let note = systemAudio ? "" : " (microphone only: system audio unavailable)"
        return .success(
            "Recording started: \(id)\(note)",
            data: ["meeting_id": id, "system_audio": systemAudio ? "1" : "0"]
        )
    }

    /// Starts a recording from a place with no window to show an error in —
    /// the menu bar, a notification action. A start that fails there (no
    /// microphone access, no input device) was invisible: the click did
    /// nothing. Named after the detected meeting, like the hotkey's start.
    func startRecordingFromBackground(foreignVoiceDecision: ForeignVoiceDecision = .undecided) async {
        let detection = detectedMeeting
        let id = await recordingVM.startRecording(
            title: detection?.displayName ?? "Recording",
            calendarEvent: detection?.calendarEvent,
            foreignVoiceDecision: foreignVoiceDecision,
            appState: self
        )
        if id == nil, case .error = recordingVM.state {
            notificationService.notifyRecordingFailed(reason: recordingFailureReason)
        }
    }

    /// Why the last start failed, in words: the error text, not the enum case.
    private var recordingFailureReason: String {
        if case .error(let message) = recordingVM.state { return message }
        return "\(recordingVM.state)"
    }

    func commandStopRecording() async -> AppCommandResponse {
        guard recordingVM.isRecording, let id = recordingVM.currentMeetingId else {
            let message = recordingVM.isRecording ? "A recording is starting" : "Nothing is recording"
            return .failure(message, reason: .notReady)
        }
        guard await recordingVM.stopRecording(appState: self) else {
            return .failure("Recording \(id) is already stopping", reason: .notReady)
        }
        return .success("Recording stopped: \(id)", data: ["meeting_id": id])
    }

    func commandLiveTranscript(last: Double?, precise: Bool) async -> AppCommandResponse {
        guard recordingVM.isRecording, let meetingId = recordingVM.currentMeetingId else {
            let message = recordingVM.isRecording ? "A recording is starting" : "Nothing is recording"
            return .failure(message, reason: .notReady)
        }
        guard let live = recordingVM.liveTranscript else {
            return .failure(
                "Live transcript is switched off in Settings → Recording, or was when this recording started",
                reason: .notReady
            )
        }
        if precise {
            await live.refine(last: last ?? MeetingLiveTranscript.tailSeconds)
        }
        // Fail closed: without the marks there is no telling what must stay hidden.
        let marks: [MeetingMark]
        do {
            marks = try await liveExclusionMarks(meetingId)
        } catch {
            return .failure("Live transcript: could not read the exclusion marks — \(error.localizedDescription)", reason: .failed)
        }
        return LiveTranscriptCommand.response(
            meetingId: meetingId,
            snapshot: await live.snapshot(),
            last: last,
            marks: marks,
            vocabulary: TermNormalizer.loadVocabulary()
        )
    }

    /// What live text is hidden by: the meeting's marks and a call mute still
    /// going on, which has no mark yet — marks are written closed.
    private func liveExclusionMarks(_ meetingId: String) async throws -> [MeetingMark] {
        var marks = try await MarkRepository().marks(for: meetingId)
        if let mutedSince = muteMonitor.openMuteStart {
            marks.append(MeetingMark(
                meetingId: meetingId, startTime: mutedSince, endTime: nil,
                track: .mic, kind: .excluded, source: .zoomMute
            ))
        }
        return marks
    }

    /// The live text of `meetingId` for its window: the same log, the same
    /// hiding and the same vocabulary as `vedivox live`. nil — it is not the
    /// meeting being recorded, or live transcript is off for this recording.
    func liveTranscriptTurns(
        for meetingId: String, normaliser: LiveTranscriptCommand.Normaliser
    ) async -> [LiveTranscriptLog.Turn]? {
        guard recordingVM.isRecording, recordingVM.currentMeetingId == meetingId,
              let live = recordingVM.liveTranscript
        else { return nil }
        // Fail closed, as the command does: no marks, no text.
        guard let marks = try? await liveExclusionMarks(meetingId) else { return [] }
        return LiveTranscriptCommand.turns(snapshot: await live.snapshot(), last: nil, marks: marks, normaliser: normaliser)
    }

    func commandCompactAudio(dryRun: Bool) async -> AppCommandResponse {
        // From the database, not the sidebar cache: that one is empty for the first seconds of a run.
        let all: [Meeting]
        do {
            all = try await meetingRepo.all()
        } catch {
            let message = "Compact: could not read the meeting list — \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }
        let ids = all.reversed().map(\.id) // all() is newest first; the run goes oldest first
        let repo = meetingRepo
        let compactor = AudioCompactor(
            audioRoot: DataDirectory.audio,
            dryRun: dryRun,
            isRecording: { await MainActor.run { self.recordingVM.isRecording || [.starting, .recording].contains(self.dictationController.state) } },
            status: { try? await repo.find($0)?.status }
        )
        // Hours of decoding and encoding: off the main actor.
        let report = await Task.detached(priority: .utility) { await compactor.run(meetingIds: ids) }.value
        return report.response
    }

    func commandCreateSeries(name: String, calendarSeriesId: String?) async -> AppCommandResponse {
        let result: (series: MeetingSeries, created: Bool)
        do {
            result = try await SeriesRepository().createOrReuse(
                MeetingSeries(name: name, calendarSeriesId: calendarSeriesId)
            )
        } catch {
            let message = "Could not create series “\(name)”: \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }

        let series = result.series
        guard result.created else {
            return .success("Series “\(series.name)” already exists (id: \(series.id))")
        }
        await refreshAfterExternalChange()
        return .success("Created series “\(name)” (id: \(series.id))")
    }

    func commandUpdateSeries(id: String, fields: [String: String]) async -> AppCommandResponse {
        let repo = SeriesRepository()
        guard var series = try? await repo.find(id) else {
            let message = "Series \(id) not found"
            Log.error("update_series: \(message)")
            return .failure(message, reason: .notFound)
        }
        if let name = fields["name"] {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure("Series name is empty", reason: .invalidParameters) }
            series.name = trimmed
        }
        if let calendarSeriesId = fields["calendar_series_id"] {
            series.calendarSeriesId = calendarSeriesId.isEmpty ? nil : calendarSeriesId
        }
        if let pattern = fields["auto_rule_pattern"] {
            guard pattern.isEmpty || SeriesAutoRule.isValidPattern(pattern) else {
                return .failure("Invalid auto-rule pattern “\(pattern)”", reason: .invalidParameters)
            }
            series.autoRulePattern = pattern.isEmpty ? nil : pattern
        }
        var assigned = 0
        do {
            try await repo.save(series)
            // The editor sheet offers the retroactive pass as a checkbox; the
            // socket has no dialog, so the pattern is applied to series-less
            // meetings right away — also when unchanged: that is the CLI's bulk
            // re-run over existing meetings.
            if fields["auto_rule_pattern"] != nil, series.autoRulePattern != nil {
                assigned = try await repo.applyRuleRetroactively(series)
            }
        } catch {
            let message = "Could not update series \(id): \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }

        await refreshAfterExternalChange()
        var summary = "Updated series “\(series.name)”: \(fields.keys.sorted().joined(separator: ", "))"
        if assigned > 0 { summary += ", meetings auto-assigned: \(assigned)" }
        return .success(summary)
    }

    func commandDeleteSeries(id: String) async -> AppCommandResponse {
        let repo = SeriesRepository()
        guard let series = try? await repo.find(id) else {
            let message = "Series \(id) not found"
            Log.error("delete_series: \(message)")
            return .failure(message, reason: .notFound)
        }
        let unlinked = (try? await repo.meetingsForSeries(id).count) ?? 0
        do {
            try await repo.delete(series)
        } catch {
            let message = "Could not delete series \(id): \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }

        await refreshAfterExternalChange()
        return .success("Deleted series “\(series.name)” (id: \(id)), meetings unlinked: \(unlinked)")
    }

    func commandMergeSeries(sourceId: String, targetId: String) async -> AppCommandResponse {
        let merged: (target: MeetingSeries, source: MeetingSeries, moved: Int, droppedCalendarId: String?)?
        do {
            merged = try await SeriesRepository().merge(sourceId, into: targetId)
        } catch {
            let message = "Could not merge series \(sourceId) into \(targetId): \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }
        guard let merged else {
            let message = "Series \(sourceId) or \(targetId) not found"
            Log.error("merge_series: \(message)")
            return .failure(message, reason: .notFound)
        }

        await refreshAfterExternalChange()
        var summary = "Merged series “\(merged.source.name)” into “\(merged.target.name)” (id: \(merged.target.id)), "
            + "meetings moved: \(merged.moved)"
        if let dropped = merged.droppedCalendarId {
            summary += "\nkept the calendar link of “\(merged.target.name)”; the merged series was linked to \(dropped)"
                + " — if that is the live event: vedivox series set \(merged.target.id.prefix(8)) --calendar-series-id \(dropped)"
        }
        return .success(summary)
    }

    func commandApplySeriesRules(dryRun: Bool) async -> AppCommandResponse {
        let result: [(series: MeetingSeries, count: Int)]
        do {
            result = try await SeriesRepository().applyAllRules(dryRun: dryRun)
        } catch {
            let message = "Could not apply series rules: \(error.localizedDescription)"
            Log.error(message)
            return .failure(message, reason: .failed)
        }
        if !dryRun { await refreshAfterExternalChange() }
        let total = result.reduce(0) { $0 + $1.count }
        let lines = result.map { "  \($0.series.name) (\($0.series.id.prefix(8))): \($0.count)" }
        let head = dryRun ? "would assign \(total) meeting(s)" : "meetings auto-assigned: \(total)"
        return .success(([head] + lines).joined(separator: "\n"), data: ["assigned": String(total)])
    }

    func commandMarkExcluded(meetingId: String, from: Double, to: Double, track: String?) async -> AppCommandResponse {
        guard await resolveMeeting(meetingId) != nil else {
            let message = "Meeting \(meetingId) not found"
            Log.error("mark_excluded: \(message)")
            return .failure(message, reason: .notFound)
        }
        guard let trackValue = SegmentSource(rawValue: track ?? SegmentSource.mic.rawValue) else {
            return .failure("Unknown track “\(track ?? "")»", reason: .invalidParameters)
        }

        do {
            let marks = MarkRepository()
            try await marks.add(MeetingMark(
                meetingId: meetingId, startTime: from, endTime: to,
                track: trackValue, kind: .excluded, source: .manual
            ))
            let result = try await marks.reprojectAndRecalc(meetingId: meetingId)
            await refreshAfterMarkChange()
            return .success(
                "Interval \(Self.formatSeconds(from))–\(Self.formatSeconds(to)) (\(trackValue.rawValue)) excluded from the transcript, segments hidden: \(result.changedSegmentIds.count)"
            )
        } catch {
            let message = "Could not mark the interval: \(error.localizedDescription)"
            Log.error("mark_excluded: \(message)")
            return .failure(message, reason: .failed)
        }
    }

    func commandUnmark(meetingId: String, markId: Int64?, from: Double?, to: Double?, track: String?) async -> AppCommandResponse {
        guard await resolveMeeting(meetingId) != nil else {
            let message = "Meeting \(meetingId) not found"
            Log.error("unmark: \(message)")
            return .failure(message, reason: .notFound)
        }

        let marks = MarkRepository()
        do {
            if let markId {
                guard try await marks.delete(id: markId, meetingId: meetingId) else {
                    return .failure("Mark \(markId) not found in meeting \(meetingId)", reason: .notFound)
                }
                let result = try await marks.reprojectAndRecalc(meetingId: meetingId)
                await refreshAfterMarkChange()
                return .success("Mark \(markId) removed, segments restored: \(result.changedSegmentIds.count)")
            }

            guard let from, let to else {
                return .failure("Needs either mark_id or from/to", reason: .invalidParameters)
            }
            guard let trackValue = SegmentSource(rawValue: track ?? SegmentSource.mic.rawValue) else {
                return .failure("Unknown track “\(track ?? "")»", reason: .invalidParameters)
            }
            try await marks.add(MeetingMark(
                meetingId: meetingId, startTime: from, endTime: to,
                track: trackValue, kind: .included, source: .manual
            ))
            let result = try await marks.reprojectAndRecalc(meetingId: meetingId)
            await refreshAfterMarkChange()
            return .success(
                "Interval \(Self.formatSeconds(from))–\(Self.formatSeconds(to)) (\(trackValue.rawValue)) returned to the transcript, segments: \(result.changedSegmentIds.count)"
            )
        } catch {
            let message = "Could not clear the mark: \(error.localizedDescription)"
            Log.error("unmark: \(message)")
            return .failure(message, reason: .failed)
        }
    }

    /// Mark edits recalculate canonicals (design D5), so the drift monitor
    /// must re-check right away — the whole point is closing the window where
    /// the next meeting is processed against a stale canonical.
    private func refreshAfterMarkChange() async {
        _ = await driftAlerts(force: true)
        await refreshAfterExternalChange()
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.1fs", value)
    }

    /// Brings the interface back in step after a command changed the data.
    ///
    /// Explicit rather than observed: the app made the change itself, so it
    /// knows exactly when to refresh, and there is no longer a foreign writer
    /// to be surprised by.
    func refreshAfterExternalChange() async {
        await loadMeetings()
        await loadSeries()
        transcriptVersion += 1
    }
}
