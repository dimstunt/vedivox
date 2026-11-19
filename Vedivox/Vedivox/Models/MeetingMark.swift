import Foundation
import GRDB

// MARK: - Mark Kind / Source

// Kind and source are string-backed structs, not enums: a build reads any
// value a newer build wrote instead of failing to decode the row, which made
// a whole meeting unopenable (2026-10-26, `zoomMute` read by an older build).
// An unknown kind is neither excluded nor included; an unknown source is just
// another non-auto mark. Both round-trip unchanged through trim/split/merge.

struct MarkKind: RawRepresentable, Hashable, Codable, Sendable, DatabaseValueConvertible {
    let rawValue: String
    static let excluded = MarkKind(rawValue: "excluded")
    static let included = MarkKind(rawValue: "included")
    /// Not a visibility mark: the call app (Zoom, Teams — named after the first)
    /// showed the owner unmuted here, so mic speech went into the call and the
    /// foreign-voice rule leaves it alone (zoom-unmuted-keeps-mic). Projection ignores it.
    static let zoomUnmuted = MarkKind(rawValue: "zoomUnmuted")
    /// Not a visibility mark either: the mic voice here went unnamed, but its
    /// best candidate was the owner, so the foreign-voice rule leaves it alone
    /// Re-derived by mic attribution on every processing pass.
    static let ownerLikely = MarkKind(rawValue: "ownerLikely")
    /// Verdict (listen-queue): speech of the track in the interval belongs to
    /// `speakerId`. Re-applied after every processing pass, never hides anything.
    static let speaker = MarkKind(rawValue: "speaker")
    /// The voice in the interval was listened to and left unnamed; keeps it out
    /// of the listen queue across reprocess.
    static let skipped = MarkKind(rawValue: "skipped")

    /// The kinds that decide transcript visibility (`MarkRepository.marks(for:)`).
    static let visibility: [MarkKind] = [.excluded, .included]
    /// The kinds written by a listening decision (`MarkRepository.verdicts(for:)`).
    static let verdicts: [MarkKind] = [.speaker, .skipped]
}

struct MarkSource: RawRepresentable, Hashable, Codable, Sendable, DatabaseValueConvertible {
    let rawValue: String
    static let button = MarkSource(rawValue: "button")
    static let manual = MarkSource(rawValue: "manual")
    static let auto = MarkSource(rawValue: "auto")
    /// Dictation made while the meeting was recording.
    static let dictation = MarkSource(rawValue: "dictation")
    /// Mic speech while the owner was muted in Zoom (zoom-mute-exclusion).
    /// A record of a live event, so reprocess keeps it like `.button`.
    static let zoomMute = MarkSource(rawValue: "zoomMute")
    /// Same as `.zoomMute`, read from Microsoft Teams.
    static let teamsMute = MarkSource(rawValue: "teamsMute")
    /// Bulk pinning of the current attribution before a reprocess
    /// (`vedivox meeting pin-speakers`); kept out of the manual-work metric.
    static let pin = MarkSource(rawValue: "pin")
}

// MARK: - MeetingMark

/// A time interval of one track marked "not for the transcript" (or explicitly
/// brought back). Source of truth for segment exclusion: segments carry only a
/// derived `isExcluded` cache, recomputed by `MarkRepository.reproject`.
///
/// Lives in its own table so it survives reprocess — `transcript_segments`
/// rows are deleted and recreated with new ids, marks are keyed by meeting
/// and time instead.
///
/// `endTime` is nil while a recording-time button interval is still open;
/// projection treats an open interval as extending to the end of the meeting.
struct MeetingMark: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var meetingId: String
    var startTime: Double
    var endTime: Double?
    var track: SegmentSource
    var kind: MarkKind
    var source: MarkSource
    var createdAt: Date
    /// The dictated text, for `source == .dictation` marks only.
    var text: String?
    /// The speaker a `.speaker` verdict names; nil on every other kind.
    var speakerId: String?

    static let databaseTableName = "meeting_marks"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let meetingId = Column(CodingKeys.meetingId)
        static let startTime = Column(CodingKeys.startTime)
        static let endTime = Column(CodingKeys.endTime)
        static let track = Column(CodingKeys.track)
        static let kind = Column(CodingKeys.kind)
        static let createdAt = Column(CodingKeys.createdAt)
        static let speakerId = Column(CodingKeys.speakerId)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    init(
        id: Int64? = nil,
        meetingId: String,
        startTime: Double,
        endTime: Double? = nil,
        track: SegmentSource = .mic,
        kind: MarkKind = .excluded,
        source: MarkSource = .manual,
        createdAt: Date = Date(),
        text: String? = nil,
        speakerId: String? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.startTime = startTime
        self.endTime = endTime
        self.track = track
        self.kind = kind
        self.source = source
        self.createdAt = createdAt
        self.text = text
        self.speakerId = speakerId
    }
}
