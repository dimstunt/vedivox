import Foundation

// MARK: - Default behaviour

/// What to do with foreign voices on the mic track when nobody has ruled on a
/// meeting yet (`foreign-voices-on-mic`, решение 5).
///
/// Two independent axes — «спрашивать или нет» and «что сделать до ответа» —
/// which is why there are four values and not three: hiding at once and still
/// asking is a real thing to want.
enum ForeignVoiceDefault: String, CaseIterable, Identifiable, Sendable {
    /// Hidden right away, with an offer to bring it back. The default: foreign
    /// speech on the mic is usually in the way, and hiding is reversible.
    case askHiding
    /// Left visible, with an offer to hide it.
    case askKeeping
    /// Hidden, no question asked. The meeting window still reports what it hid.
    case hideSilently
    /// Left visible, no question asked.
    case keepSilently

    var id: String { rawValue }

    static let defaultsKey = "foreignVoiceDefault"
    static let fallback: ForeignVoiceDefault = .askHiding

    static var current: ForeignVoiceDefault {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(ForeignVoiceDefault.init(rawValue:)) ?? fallback
    }

    /// Hide foreign speech before anyone is asked.
    var hides: Bool { self == .askHiding || self == .hideSilently }
    /// Put the question to the user at all.
    var asks: Bool { self == .askHiding || self == .askKeeping }

    var title: String {
        switch self {
        case .askHiding: "Hide and ask"
        case .askKeeping: "Keep and ask"
        case .hideSilently: "Hide without asking"
        case .keepSilently: "Keep without asking"
        }
    }
}

// MARK: - Policy

/// Foreign voices on the mic track: who counts as foreign, and what happens to
/// them by default (`foreign-voices-on-mic`, решения 4–7).
struct ForeignVoicePolicy {
    private let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    /// A foreign segment is a mic-track segment whose speaker is not the owner
    /// (решение 4). Unidentified speech is a special case of that, not the
    /// definition — the wife the system knows by name is just as much
    /// background on a call as the nameless neighbour.
    ///
    /// The system track never qualifies, under any setting: the people on it
    /// are the ones the meeting was recorded for.
    ///
    /// Without an isMe speaker the rule does not apply at all — otherwise
    /// everyone would be foreign.
    ///
    /// Nor without a single segment on the system track: with
    /// nobody on a call the mic carries the whole meeting — an in-person one
    /// through one microphone — so the people on it are the participants, not
    /// background.
    ///
    /// Mic speech while Zoom showed the owner unmuted went into the call, so it
    /// is not foreign whoever said it: a segment at least half inside such a
    /// window (`zoomUnmuted` marks) does not qualify (zoom-unmuted-keeps-mic D4).
    ///
    /// «Не опознан» is not «уверенно чужой»: a voice the matcher
    /// left unnamed although the owner was its best candidate sits inside an
    /// `ownerLikely` window and does not qualify either. On his own mic the
    /// presumption is the owner's; a near miss of his threshold used to hide
    /// 54 seconds of his own speech.
    static func foreignSegments(
        _ segments: [TranscriptSegment],
        ownerId: String?,
        marks: [MeetingMark] = []
    ) -> [TranscriptSegment] {
        guard let ownerId, segments.contains(where: { $0.source == .system }) else { return [] }
        let unmuted = marks.filter(keepsMicSpeech)
        return segments.filter { segment in
            guard segment.source == .mic, segment.speakerId != ownerId else { return false }
            let duration = segment.endTime - segment.startTime
            let inCall = unmuted.reduce(0.0) { covered, window in
                let end = window.endTime ?? .greatestFiniteMagnitude
                return covered + max(0, min(end, segment.endTime) - max(window.startTime, segment.startTime))
            }
            return duration <= 0 || inCall < ExclusionProjection.coverageThreshold * duration
        }
    }

    /// Windows of the mic track whose speech is never foreign, whoever it is
    /// attributed to. One definition for the policy and the meeting window.
    static func keepsMicSpeech(_ mark: MeetingMark) -> Bool {
        mark.track == .mic && (mark.kind == .zoomUnmuted || mark.kind == .ownerLikely)
    }

    /// Titles for the meeting's speaker filter, by label. A speaker
    /// whose every segment is hidden says so — picking them shows an empty
    /// transcript and nothing told why — and one of the `undecided` foreign
    /// voices also repeats the banner's question, so the list shows there is
    /// something to decide about them.
    static func speakerFilterTitles(
        _ segments: [TranscriptSegment],
        undecided: [TranscriptSegment]
    ) -> [(label: String, title: String)] {
        let asked = Set(undecided.compactMap(\.id))
        var byLabel: [String: (hidden: Bool, asked: Bool)] = [:]
        for segment in segments {
            guard let label = segment.speakerLabel else { continue }
            let seen = byLabel[label] ?? (true, false)
            byLabel[label] = (seen.hidden && segment.isExcluded, seen.asked || segment.id.map(asked.contains) == true)
        }
        return byLabel.sorted { $0.key < $1.key }.map { label, state in
            let name = Speaker.windowLabel(label)
            guard state.hidden else { return (label, name) }
            return (label, state.asked ? "\(name) — hidden · participant or background?" : "\(name) — hidden")
        }
    }

    /// Merges segment time ranges into as few intervals as possible, per track —
    /// one mark per contiguous stretch instead of one per segment.
    static func coalescedIntervals(
        of targets: [TranscriptSegment]
    ) -> [(track: SegmentSource, start: Double, end: Double)] {
        var result: [(track: SegmentSource, start: Double, end: Double)] = []
        let byTrack = Dictionary(grouping: targets, by: \.source)
        for (track, group) in byTrack.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let sorted = group.sorted { $0.startTime < $1.startTime }
            var current: (start: Double, end: Double)?
            for segment in sorted {
                if var run = current, segment.startTime <= run.end {
                    run.end = max(run.end, segment.endTime)
                    current = run
                } else {
                    if let run = current { result.append((track, run.start, run.end)) }
                    current = (segment.startTime, segment.endTime)
                }
            }
            if let run = current { result.append((track, run.start, run.end)) }
        }
        return result
    }

    /// Cuts the user's own intervals — button and manual marks, of either
    /// kind — out of the auto intervals, per track. What the user decided is
    /// never re-marked, so a reprocess cannot outrank a stretch they brought
    /// back, and a button interval never gets a second, auto mark on top
    /// (exclusion-marks-fixes, design D1). An open end means «to the end».
    static func subtracting(
        userIntervals: [(track: SegmentSource, start: Double, end: Double?)],
        from intervals: [(track: SegmentSource, start: Double, end: Double)]
    ) -> [(track: SegmentSource, start: Double, end: Double)] {
        var result: [(track: SegmentSource, start: Double, end: Double)] = []
        for interval in intervals {
            var pieces = [(start: interval.start, end: interval.end)]
            for user in userIntervals where user.track == interval.track {
                let userEnd = user.end ?? .greatestFiniteMagnitude
                pieces = pieces.flatMap { piece -> [(start: Double, end: Double)] in
                    guard user.start < piece.end, userEnd > piece.start else { return [piece] }
                    var kept: [(start: Double, end: Double)] = []
                    if user.start > piece.start { kept.append((piece.start, user.start)) }
                    if userEnd < piece.end { kept.append((userEnd, piece.end)) }
                    return kept
                }
            }
            result += pieces.filter { $0.end > $0.start }.map { (interval.track, $0.start, $0.end) }
        }
        return result
    }

    /// Applies the default to a freshly processed meeting (решение 7).
    ///
    /// A ruling — the user's, a silently applied default, or «несколько людей
    /// на микрофоне» pinned onto the recording up front — is never replayed
    /// against the current setting (решение 6): it *becomes* the setting for
    /// this pass. Auto marks are still re-derived every pass, because
    /// processing replaces every segment and marks drawn over the previous
    /// segmentation land on other people's words — on 2026-09-04 that hid all
    /// 139 mic segments of a meeting, the owner's own speech included.
    func applyDefault(
        meetingId: String,
        setting: ForeignVoiceDefault = .current
    ) async throws {
        let meetingRepo = MeetingRepository(db: db)
        guard let meeting = try await meetingRepo.find(meetingId) else { return }
        let effective: ForeignVoiceDefault = switch meeting.foreignVoiceDecision {
        case .undecided: setting
        case .hidden: .hideSilently
        case .kept: .keepSilently
        }

        // The auto marks describe segments this pass has just replaced, so they
        // go before any early return: a meeting whose foreign voices are gone
        // would otherwise keep marks pointing at a segmentation that no longer
        // exists.
        let markRepo = MarkRepository(db: db)
        try await markRepo.deleteAuto(meetingId: meetingId)

        let owner = try await SpeakerRepository(db: db).findMe()
        if owner == nil {
            Log.info("Foreign voices: no isMe speaker — the rule does not apply to \(meetingId)")
        }
        let segments = try await meetingRepo.segments(for: meetingId)
        let marks = try await markRepo.marks(for: meetingId)
        let foreign = owner.map { Self.foreignSegments(segments, ownerId: $0.id, marks: marks) } ?? []

        if effective.hides, !foreign.isEmpty {
            try await hide(foreign, meetingId: meetingId)
        }
        try await markRepo.reprojectAndRecalc(meetingId: meetingId)

        guard !foreign.isEmpty else { return }
        if !effective.asks {
            let decision: ForeignVoiceDecision = effective.hides ? .hidden : .kept
            try await meetingRepo.updateForeignVoiceDecision(meetingId, decision)
        }
        Log.info("Foreign voices in \(meetingId): \(foreign.count) segment(s), \(effective.rawValue) → hidden=\(effective.hides) asked=\(effective.asks)")
    }

    /// Lays exclusion marks over foreign stretches. Marked `.auto` so a
    /// reprocess can re-derive them without touching the user's own marks or
    /// the recording-time «не в транскрипт» intervals. The caller has already
    /// dropped the previous auto marks and reprojects afterwards.
    private func hide(_ segments: [TranscriptSegment], meetingId: String) async throws {
        let markRepo = MarkRepository(db: db)
        // Only the user's marks are left at this point.
        let userIntervals = try await markRepo.marks(for: meetingId)
            .map { (track: $0.track, start: $0.startTime, end: $0.endTime) }
        for interval in Self.subtracting(userIntervals: userIntervals, from: Self.coalescedIntervals(of: segments)) {
            try await markRepo.add(MeetingMark(
                meetingId: meetingId,
                startTime: interval.start,
                endTime: interval.end,
                track: interval.track,
                kind: .excluded,
                source: .auto
            ))
        }
    }
}
