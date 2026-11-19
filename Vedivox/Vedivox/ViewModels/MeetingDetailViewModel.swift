import Foundation
import SwiftUI

@MainActor
@Observable
final class MeetingDetailViewModel {
    enum EditMode: Equatable {
        case split
        case trim
    }

    var meeting: Meeting?
    var segments: [TranscriptSegment] = []
    var isLoading = false
    /// Voices of this meeting waiting in the Listen section (the header chip).
    var voicesToCheck = 0
    /// The speaker marked as "me" (set in Speakers tab), nil if not configured.
    var meSpeaker: Speaker?
    /// Currently selected speaker filter; nil = show all.
    var speakerFilter: String?
    /// Whose lines the transcript shows, `.mix` = both tracks. The
    /// player's track type, not its state: what is heard and what is read stay apart.
    var trackFilter: AudioTrack = .mix
    /// «Exclude mic track» is in force on this meeting.
    var micTrackExcluded = false
    /// Text search within transcript segments.
    var searchText: String = ""
    /// Meeting description text for editing.
    var descriptionText: String = ""
    /// IDs of segments selected for batch operations.
    var selectedSegmentIds: Set<Int64> = []
    /// Show excluded segments (dimmed) instead of hiding them.
    var showExcluded = false
    /// Dictations made while this meeting recorded, shown as plaques.
    var dictations: [MeetingMark] = []
    /// Mic stretches whose speech is never foreign: Zoom showed the owner
    /// unmuted (zoom-unmuted-keeps-mic), or the voice went unnamed with the
    /// owner as its best candidate.
    var notForeignWindows: [MeetingMark] = []

    /// Coalesced excluded stretches, drawn as red zones on the player
    /// waveform — the waveform is the meeting timeline (D7, увеличение C).
    var excludedZones: [(id: Int64, start: Double, end: Double)] {
        let excluded = segments.filter(\.isExcluded).sorted { $0.startTime < $1.startTime }
        var zones: [(id: Int64, start: Double, end: Double)] = []
        for segment in excluded {
            guard let segmentId = segment.id else { continue }
            if var last = zones.last, segment.startTime <= last.end + 0.5 {
                last.end = max(last.end, segment.endTime)
                zones[zones.count - 1] = last
            } else {
                zones.append((segmentId, segment.startTime, segment.endTime))
            }
        }
        return zones
    }

    // MARK: - Edit Mode (Split / Trim)

    var editMode: EditMode?
    /// Split point = startTime of the clicked segment.
    var splitTime: Double?
    /// Trim range boundaries (startTime of first clicked, endTime of second clicked).
    var trimFromTime: Double?
    var trimToTime: Double?
    var canUndoSplit: Bool = false
    var canUndoTrim: Bool = false
    var canUndoMerge: Bool = false

    var uniqueSpeakerLabels: [String] {
        Set(segments.compactMap(\.speakerLabel)).sorted()
    }

    /// The speaker filter's choices: a fully hidden speaker is marked as such,
    /// with the participant-or-background question while it is open.
    var speakerFilterOptions: [(String?, String)] {
        [(nil, "All speakers")] + ForeignVoicePolicy
            .speakerFilterTitles(segments, undecided: showForeignPrompt ? foreignMicSegments : [])
            .map { (String?.some($0.label), $0.title) }
    }

    var filteredSegments: [TranscriptSegment] {
        var result = segments
        if !showExcluded {
            result = result.filter { !$0.isExcluded }
        }
        if let filter = speakerFilter {
            result = result.filter { $0.speakerLabel == filter }
        }
        switch trackFilter {
        case .mix: break
        case .mic: result = result.filter { $0.source == .mic }
        case .system: result = result.filter { $0.source == .system }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    // MARK: - Exclusion ("не в транскрипт")

    var excludedCount: Int {
        segments.count(where: \.isExcluded)
    }

    var excludedDuration: Double {
        segments.filter(\.isExcluded).reduce(0) { $0 + max(0, $1.endTime - $1.startTime) }
    }

    let playback = AudioPlaybackService()
    /// The meeting whose audio `playback` holds. `meeting` switches before the
    /// audio does, so a remembered position is keyed by this, not by `meeting`.
    private var audioMeetingId: String?

    /// Where the player stands in the loaded audio; nil while none is loaded
    /// (duration 0), so a quick pass through a meeting does not overwrite its
    /// remembered position. Played to the end resumes from the start.
    var leavingPosition: (meetingId: String, time: TimeInterval)? {
        guard let id = audioMeetingId, playback.duration > 0 else { return nil }
        let time = playback.currentTime
        return (id, time < playback.duration ? time : 0)
    }

    /// Pre-rendered waveform peaks for the player bar (nil while computing).
    var waveformPeaks: WaveformPeaks?
    var autoScrollEnabled = true
    /// Set true during programmatic scrolls to prevent `onScrollGeometryChange` from disabling auto-scroll.
    var isProgrammaticScroll = false

    var activeSegmentId: Int64? {
        guard playback.isPlaying || playback.currentTime > 0 else { return nil }
        let time = playback.currentTime
        return segments.last { $0.startTime <= time }?.id
    }

    // MARK: - Split/Trim Preview

    struct SplitPreview {
        let part1Segments: Int
        let part2Segments: Int
        let splitTime: Double
        let duration: Double
    }

    struct TrimPreview {
        let keepSegments: Int
        let removeSegments: Int
        let from: Double
        let to: Double
    }

    var splitPreview: SplitPreview? {
        guard editMode == .split, let splitTime,
              let duration = meeting?.durationSeconds ?? segments.last?.endTime else { return nil }
        let part1 = segments.filter { $0.endTime <= splitTime }.count
        let part2 = segments.filter { $0.startTime >= splitTime }.count
        return SplitPreview(part1Segments: part1, part2Segments: part2, splitTime: splitTime, duration: duration)
    }

    var trimPreview: TrimPreview? {
        guard editMode == .trim, let from = trimFromTime, let to = trimToTime, to > from else { return nil }
        let keep = segments.filter { $0.startTime >= from && $0.endTime <= to }.count
        let remove = segments.count - keep
        return TrimPreview(keepSegments: keep, removeSegments: remove, from: from, to: to)
    }

    func enterEditMode(_ mode: EditMode) {
        editMode = mode
        splitTime = nil
        trimFromTime = nil
        trimToTime = nil
        selectedSegmentIds.removeAll()
    }

    func exitEditMode() {
        editMode = nil
        splitTime = nil
        trimFromTime = nil
        trimToTime = nil
    }

    func handleEditModeTap(segment: TranscriptSegment) {
        switch editMode {
        case .split:
            splitTime = segment.startTime
        case .trim:
            if trimFromTime == nil {
                trimFromTime = segment.startTime
            } else if trimToTime == nil {
                let to = segment.endTime
                if to > trimFromTime! {
                    trimToTime = to
                } else {
                    trimFromTime = segment.startTime
                }
            } else {
                trimFromTime = segment.startTime
                trimToTime = nil
            }
        case nil:
            break
        }
    }

    /// Whether a segment is at or past the split point (will move to meeting2).
    func isSegmentInPart2(_ segment: TranscriptSegment) -> Bool {
        guard editMode == .split, let splitTime else { return false }
        return segment.startTime >= splitTime
    }

    /// Whether a segment is outside the trim range (will be removed).
    func isSegmentTrimmed(_ segment: TranscriptSegment) -> Bool {
        guard editMode == .trim, let from = trimFromTime else { return false }
        if let to = trimToTime {
            return segment.endTime <= from || segment.startTime >= to
        }
        return segment.endTime <= from
    }

    func checkUndoAvailability() async {
        guard let meetingId = meeting?.id else {
            canUndoSplit = false
            canUndoTrim = false
            canUndoMerge = false
            return
        }
        canUndoTrim = meetingRepo.canUndoTrim(meetingId)
        canUndoSplit = await meetingRepo.canUndoSplit(meetingId)
        canUndoMerge = meetingRepo.canUndoMerge(meetingId)
    }

    private let meetingRepo = MeetingRepository()
    private let speakerRepo = SpeakerRepository()
    private let markRepo = MarkRepository()

    @ObservationIgnored private var loadGeneration = 0

    /// What the player currently holds — see `audioSignature`.
    @ObservationIgnored private var loadedAudioSignature: String?

    /// Path, size and modification time of each track: a trim, a split, a
    /// merge or a reprocess leaves new files under the same names.
    private static func audioSignature(_ urls: URL?...) -> String {
        urls.map { url -> String in
            guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "-" }
            return "\(url.path)|\(attributes[.size] ?? 0)|\(attributes[.modificationDate] ?? 0)"
        }.joined(separator: "\n")
    }

    /// Refreshes the transcript after an edit of `meetingId` — unless the user
    /// has opened another meeting while the edit ran (recalculating a voice
    /// profile can take seconds). Assigning anyway showed the old meeting's
    /// transcript under the new one's header, and the next rename or exclude
    /// was applied to the new meeting with the old one's labels and times.
    private func reloadSegments(of meetingId: String) async throws {
        let fresh = try await meetingRepo.segments(for: meetingId)
        guard meeting?.id == meetingId else { return }
        segments = fresh
    }

    /// After a committed speaker change: a failed reload must not cost its undo.
    private func reloadCommitted(_ meetingId: String) async {
        do {
            try await reloadSegments(of: meetingId)
        } catch {
            Log.error("Reload of \(meetingId) after a speaker change failed: \(error)")
        }
    }

    /// `resumeAt` goes through the deferred seek of a loading player
    /// it lands once the files are open, without playing.
    func load(meetingId: String, resumeAt: TimeInterval = 0) async {
        let loadStart = CFAbsoluteTimeGetCurrent()
        // Loads overlap (a click on another meeting during a reload, which
        // nothing cancels). Each await below can resume after a newer load
        // has started; assigning then put one meeting's transcript under
        // another's header, and the next edit went into the wrong meeting.
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        do {
            let dbStart = CFAbsoluteTimeGetCurrent()
            async let meetingResult = meetingRepo.find(meetingId)
            async let segmentsResult = meetingRepo.segments(for: meetingId)
            async let meSpeakerResult = speakerRepo.findMe()

            // Typing not saved yet survives a reload of the meeting on
            // screen (any external change triggers one); another meeting
            // always brings its own text. Set together with `meeting`, with
            // no await in between: the editor's text and the meeting it
            // belongs to must never be seen apart.
            let previous = meeting
            let loaded = try await meetingResult
            guard generation == loadGeneration else { return }
            let keepsTyping = previous?.id == meetingId && descriptionText != (previous?.description ?? "")
            meeting = loaded
            if !keepsTyping { descriptionText = loaded?.description ?? "" }
            let meetingReady = Int((CFAbsoluteTimeGetCurrent() - dbStart) * 1000)
            let loadedSegments = try await segmentsResult
            guard generation == loadGeneration else { return }
            segments = loadedSegments
            let segmentsReady = Int((CFAbsoluteTimeGetCurrent() - dbStart) * 1000)
            let loadedMe = try await meSpeakerResult
            guard generation == loadGeneration else { return }
            meSpeaker = loadedMe
            let meSpeakerReady = Int((CFAbsoluteTimeGetCurrent() - dbStart) * 1000)
            let marks = try await markRepo.marks(for: meetingId)
            guard generation == loadGeneration else { return }
            dictations = marks.filter { $0.source == .dictation }
            notForeignWindows = marks.filter(ForeignVoicePolicy.keepsMicSpeech)
            micTrackExcluded = marks.contains { MarkRepository.hidesWholeTrack($0, .mic, end: trackEnd) }

            Log.info("[Perf][MeetingSwitch] \(meetingId) db N=\(segments.count) ready@: meeting=\(meetingReady)ms segments=\(segmentsReady)ms meSpeaker=\(meSpeakerReady)ms")
        } catch {
            Log.error("Failed to load meeting detail: \(error)")
        }
        guard generation == loadGeneration else { return }
        isLoading = false

        // Fire-and-forget: undo checks don't block transcript display
        Task { await checkUndoAvailability() }
        Task { await refreshVoicesToCheck() }

        // Load audio in a separate run-loop tick so transcript renders first
        var micURL: URL? = meeting?.micAudioPath.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let systemURL: URL? = meeting?.systemAudioPath.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        // Only fall back to the original import while it is a plain audio file —
        // AVAudioFile leaks its fd on .mov containers (see AudioConverter).
        if micURL == nil, let sourcePath = meeting?.sourceFilePath,
           AudioConverter.isSafeForDirectRead(URL(fileURLWithPath: sourcePath)),
           FileManager.default.fileExists(atPath: sourcePath) {
            micURL = URL(fileURLWithPath: sourcePath)
        }
        // Prefer suppressed mic for playback (echo suppression applied)
        if let mid = meeting?.id,
           let audioDir = try? DatabaseManager.audioDirectory(for: mid) {
            let suppressed = audioDir.appendingPathComponent("mic_suppressed.m4a")
            if FileManager.default.fileExists(atPath: suppressed.path) {
                micURL = suppressed
            }
        }
        let hasMic = micURL != nil
        let hasSys = systemURL != nil
        // The same files as are loaded: leave the player alone. Every external
        // change reloads the meeting on screen (another meeting finished
        // processing, any CLI/MCP command), and reloading the audio with it
        // stopped playback and threw the position back to 0:00.
        let signature = Self.audioSignature(micURL, systemURL)
        let sameAudio = audioMeetingId == meetingId && signature == loadedAudioSignature
        Task { @MainActor in
            let audioStart = CFAbsoluteTimeGetCurrent()
            if sameAudio {
                playback.meetingTitle = meeting?.title ?? ""
            } else if micURL != nil || systemURL != nil {
                playback.meetingTitle = meeting?.title ?? ""
                playback.load(micURL: micURL, systemURL: systemURL)
                if resumeAt > 0 { playback.seek(to: resumeAt) }
                audioMeetingId = meetingId
                loadedAudioSignature = signature
            } else {
                playback.stop()
                audioMeetingId = nil
                loadedAudioSignature = nil
            }
            let audioMs = Int((CFAbsoluteTimeGetCurrent() - audioStart) * 1000)
            Log.info("[Perf][MeetingSwitch] \(meetingId) audio-deferred=\(audioMs)ms mic=\(hasMic) system=\(hasSys)")
        }

        // Waveform peaks: cached JSON loads instantly, first-ever open computes
        // off-main and fills in when ready.
        if !sameAudio { waveformPeaks = nil }
        if !sameAudio, micURL != nil || systemURL != nil {
            let mic = micURL
            let system = systemURL
            Task { [weak self] in
                let peaks = await Task.detached(priority: .utility) {
                    WaveformPeaksService.load(micURL: mic, systemURL: system)
                }.value
                guard let self, self.meeting?.id == meetingId else { return }
                self.waveformPeaks = peaks
            }
        }

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - loadStart) * 1000)
        Log.info("[Perf][MeetingSwitch] \(meetingId) load-total=\(totalMs)ms (audio deferred)")
    }

    func updateSegmentText(segmentId: Int64, newText: String) async {
        do {
            try await meetingRepo.updateSegmentText(id: segmentId, text: newText)
            // Reload segments
            if let id = meeting?.id {
                try await reloadSegments(of: id)
            }
        } catch {
            Log.error("Failed to update segment: \(error)")
        }
    }

    func seekAndPlay(to time: TimeInterval) {
        let wasPlaying = playback.isPlaying
        playback.seek(to: time)
        if !wasPlaying {
            playback.play()
        }
        autoScrollEnabled = true
    }

    func pauseForEditing() {
        if playback.isPlaying {
            playback.pause()
        }
    }

    func disableAutoScroll() {
        autoScrollEnabled = false
    }

    /// `meetingId` is the meeting the text was typed in, captured by the
    /// caller at that moment. Reading `meeting?.id` here, half a second later
    /// in the debounced save, wrote the text into whatever meeting was open
    /// by then.
    func updateDescription(_ text: String, meetingId id: String) async {
        let trimmed: String? = text.isEmpty ? nil : text
        do {
            try await meetingRepo.updateDescription(id, description: trimmed)
            if meeting?.id == id { meeting?.description = trimmed }
        } catch {
            Log.error("Failed to update description: \(error)")
        }
    }

    func renameMeeting(to newTitle: String) async {
        guard !newTitle.isEmpty, let id = meeting?.id else { return }
        do {
            try await meetingRepo.updateTitle(id, title: newTitle)
            meeting?.title = newTitle
        } catch {
            Log.error("Failed to rename meeting: \(error)")
        }
    }

    func updateStartTime(_ date: Date) async {
        guard let id = meeting?.id else { return }
        do {
            try await meetingRepo.updateStartTime(id, startTime: date)
            meeting?.startTime = date
        } catch {
            Log.error("Failed to update start time: \(error)")
        }
    }

    /// Rename all segments with the same diarization label in this meeting.
    /// When `existingSpeakerId` is provided (user picked from the list), reuse that speaker directly.
    /// Returns what Edit → Undo needs to put the rename back; nil
    /// when nothing changed or the move went through verdicts.
    @discardableResult
    func renameSpeaker(
        segment: TranscriptSegment, newName: String, existingSpeakerId: String? = nil,
        run: [TranscriptSegment]? = nil
    ) async -> SpeakerUndo? {
        guard let meetingId = meeting?.id,
              let oldLabel = segment.speakerLabel else { return nil }
        if Self.isUnknown(segment) {
            let target: SpeakerVerdicts.Target = existingSpeakerId.map { .existing(speakerId: $0) } ?? .new(name: newName)
            await assign((run ?? [segment]).compactMap(\.id), to: target, what: "name an unknown run")
            return nil
        }

        do {
            let oldSpeakerId = segment.speakerId
            let undo = try await SpeakerUndo.capture(
                speakerIds: [oldSpeakerId].compactMap { $0 }, rows: [existingSpeakerId].compactMap { $0 },
                meetingIds: [meetingId]
            )
            try await speakerRepo.nameSpeakerInMeeting(
                meetingId: meetingId, oldLabel: oldLabel, newName: newName,
                existingSpeakerId: existingSpeakerId, fromSpeakerId: oldSpeakerId
            )
            await reloadCommitted(meetingId)
            return undo
        } catch {
            Log.error("Failed to rename speaker: \(error)")
            return nil
        }
    }

    /// Reassign a single segment to an existing speaker (no cascade to other segments).
    func reassignSegmentSpeaker(segmentId: Int64, speakerId: String, speakerName: String) async {
        await assign([segmentId], to: .existing(speakerId: speakerId), what: "reassign segment speaker")
    }

    /// Reassign a single segment to a new speaker (create speaker if needed).
    func reassignSegmentToNewSpeaker(segmentId: Int64, name: String) async {
        await assign([segmentId], to: .new(name: name), what: "reassign segment to new speaker")
    }

    /// Reassign all segments with this speaker label to the "me" speaker (set in Speakers tab).
    @discardableResult
    func markSpeakerAsMe(segment: TranscriptSegment, run: [TranscriptSegment]? = nil) async -> SpeakerUndo? {
        guard let meetingId = meeting?.id,
              let oldLabel = segment.speakerLabel else { return nil }

        do {
            // Find the speaker flagged as "me" — must be set in the Speakers tab first
            guard let meSpeaker = try await speakerRepo.findMe() else {
                Log.warning("No 'me' speaker set. Use the Speakers tab to mark a speaker as me first.")
                return nil
            }
            if Self.isUnknown(segment) {
                await assign((run ?? [segment]).compactMap(\.id), to: .existing(speakerId: meSpeaker.id), what: "mark an unknown run as me")
                return nil
            }
            let undo = try await SpeakerUndo.capture(
                speakerIds: [segment.speakerId].compactMap { $0 }, rows: [meSpeaker.id], meetingIds: [meetingId]
            )
            // All lines with this label go to the "me" speaker
            try await speakerRepo.nameSpeakerInMeeting(
                meetingId: meetingId, oldLabel: oldLabel, newName: meSpeaker.displayName,
                existingSpeakerId: meSpeaker.id, fromSpeakerId: segment.speakerId
            )
            await reloadCommitted(meetingId)
            return undo
        } catch {
            Log.error("Failed to assign speaker as me: \(error)")
            return nil
        }
    }

    /// UNKNOWN gathers every unrecognised voice of both tracks, not one person:
    /// an action on it moves only the lines acted on.
    static func isUnknown(_ segment: TranscriptSegment) -> Bool {
        segment.speakerId == nil && segment.speakerLabel == "UNKNOWN"
    }

    /// Copy full transcript to clipboard as plain text.
    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptExporter.plainText(segments: segments), forType: .string)
    }

    // MARK: - Multi-select batch operations

    func clearSelection() {
        selectedSegmentIds.removeAll()
    }

    /// Reassign all selected segments to an existing speaker.
    func reassignSelectedSegments(speakerId: String, speakerName: String) async {
        await assign(Array(selectedSegmentIds), to: .existing(speakerId: speakerId), what: "reassign selected segments")
    }

    /// Reassign all selected segments to a new speaker (created if needed).
    func reassignSelectedToNewSpeaker(name: String) async {
        await assign(Array(selectedSegmentIds), to: .new(name: name), what: "reassign selected segments to new speaker")
    }

    /// Reassign all selected segments to the "me" speaker.
    func markSelectedAsMe() async {
        guard let meSpeaker = try? await speakerRepo.findMe() else {
            Log.warning("No 'me' speaker set.")
            return
        }
        await assign(Array(selectedSegmentIds), to: .existing(speakerId: meSpeaker.id), what: "mark selected segments as me")
    }

    func refreshVoicesToCheck() async {
        guard let meetingId = meeting?.id else { return }
        voicesToCheck = (try? await ListenQueueBuilder().count(meetingId: meetingId)) ?? 0
    }

    /// Every hand move of lines goes through `SpeakerVerdicts` (listen-queue
    /// § 5): the verdict it writes keeps the move across reprocess.
    private func assign(_ segmentIds: [Int64], to target: SpeakerVerdicts.Target, what: String) async {
        guard let meetingId = meeting?.id, !segmentIds.isEmpty else { return }
        do {
            _ = try await SpeakerVerdicts().assign(meetingId: meetingId, segmentIds: segmentIds, to: target)
            selectedSegmentIds.subtract(segmentIds)
            try await reloadSegments(of: meetingId)
            await refreshVoicesToCheck()
        } catch {
            Log.error("Failed to \(what): \(error)")
        }
    }

    // MARK: - Exclusion marks

    /// Marks the selected segments "не в транскрипт": their times become
    /// excluded intervals (coalesced per track), the segments disappear from
    /// every read surface and stop feeding canonical embeddings.
    func excludeSelectedSegments() async {
        await applyMarks(kind: .excluded, to: selectedSegmentsSnapshot())
        selectedSegmentIds.removeAll()
    }

    /// Brings the selected segments back: lays `included` intervals over
    /// their times, which override earlier excluded intervals (design D2).
    func includeSelectedSegments() async {
        await applyMarks(kind: .included, to: selectedSegmentsSnapshot())
        selectedSegmentIds.removeAll()
    }

    /// Run-level variants for the Smart layout's context menu.
    func excludeSegments(_ targets: [TranscriptSegment]) async {
        await applyMarks(kind: .excluded, to: targets)
    }

    func includeSegments(_ targets: [TranscriptSegment]) async {
        await applyMarks(kind: .included, to: targets)
    }

    /// The track filter is offered only where there are two tracks to choose from.
    var hasBothTracks: Bool {
        segments.contains { $0.source == .mic } && segments.contains { $0.source == .system }
    }

    private var trackEnd: Double {
        max(meeting?.durationSeconds ?? 0, segments.map(\.endTime).max() ?? 0)
    }

    /// «Exclude mic track» / «Restore mic track»: one mark over the whole mic
    /// track, laid or taken away; the system track is never touched.
    func setMicTrackExcluded(_ excluded: Bool) async {
        guard let meetingId = meeting?.id else { return }
        do {
            if excluded {
                try await markRepo.excludeWholeTrack(meetingId: meetingId, track: .mic, end: trackEnd)
            } else {
                try await markRepo.restoreWholeTrack(meetingId: meetingId, track: .mic, end: trackEnd)
            }
            try await reloadSegments(of: meetingId)
            if meeting?.id == meetingId { micTrackExcluded = excluded }
        } catch {
            Log.error("Failed to \(excluded ? "exclude" : "restore") the mic track: \(error)")
        }
    }

    private func selectedSegmentsSnapshot() -> [TranscriptSegment] {
        segments.filter { $0.id.map(selectedSegmentIds.contains) ?? false }
    }

    private func applyMarks(kind: MarkKind, to targets: [TranscriptSegment]) async {
        guard let meetingId = meeting?.id, !targets.isEmpty else { return }
        do {
            for interval in ForeignVoicePolicy.coalescedIntervals(of: targets) {
                try await markRepo.add(MeetingMark(
                    meetingId: meetingId,
                    startTime: interval.start,
                    endTime: interval.end,
                    track: interval.track,
                    kind: kind,
                    source: .manual
                ))
            }
            try await markRepo.reprojectAndRecalc(meetingId: meetingId)
            try await reloadSegments(of: meetingId)
        } catch {
            Log.error("Failed to apply \(kind.rawValue) marks: \(error)")
        }
    }

    // MARK: - Foreign voices on the mic track

    /// Mic-track speech that is not the owner's (`foreign-voices-on-mic`,
    /// решение 4). Identified-by-name and unidentified alike; the system track
    /// never qualifies.
    var foreignMicSegments: [TranscriptSegment] {
        ForeignVoicePolicy.foreignSegments(segments, ownerId: meSpeaker?.id, marks: notForeignWindows)
    }

    var hiddenForeignCount: Int {
        foreignMicSegments.count(where: \.isExcluded)
    }

    /// The question is offered while nobody has ruled on this meeting and the
    /// setting says to ask. A decision — the user's, a silently applied
    /// default, or «несколько людей на микрофоне» — closes it for good.
    var showForeignPrompt: Bool {
        meeting?.foreignVoiceDecision == .undecided
            && ForeignVoiceDefault.current.asks
            && !foreignMicSegments.isEmpty
    }

    /// Решение 9: hiding without a word is indistinguishable from losing, so
    /// the meeting window reports what was hidden and offers it back.
    var showHiddenForeignNotice: Bool {
        meeting?.foreignVoiceDecision == .hidden && hiddenForeignCount > 0
    }

    /// «Фон»: hide every foreign mic stretch behind exclusion marks.
    func hideForeignVoices() async {
        await excludeSegments(foreignMicSegments.filter { !$0.isExcluded })
        await recordForeignVoiceDecision(.hidden)
    }

    /// «Участник»: bring foreign speech back (the default may have hidden it
    /// already) and stop asking. Takes effect immediately — no reprocess.
    func keepForeignVoices() async {
        await includeSegments(foreignMicSegments.filter(\.isExcluded))
        await recordForeignVoiceDecision(.kept)
    }

    private func recordForeignVoiceDecision(_ decision: ForeignVoiceDecision) async {
        guard let meetingId = meeting?.id else { return }
        do {
            try await meetingRepo.updateForeignVoiceDecision(meetingId, decision)
            meeting?.foreignVoiceDecision = decision
        } catch {
            Log.error("Failed to record foreign-voice decision: \(error)")
        }
    }

    /// Export transcript as Markdown file via NSSavePanel.
    func exportMarkdown() {
        guard let meeting else { return }
        do {
            _ = try TranscriptExporter.exportViaSavePanel(meeting: meeting, segments: segments)
        } catch {
            Log.error("Export of \(meeting.id) failed: \(error.localizedDescription)")
        }
    }
}
