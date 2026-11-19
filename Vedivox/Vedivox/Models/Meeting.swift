import Foundation
import GRDB

// MARK: - Meeting Status

enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case recording
    case transcribing
    case diarizing
    case done
    /// Processed, but a track that sounded produced no transcript (or its
    /// compressed copy failed verification) — visible, not silently `done`.
    case needsAttention
    case error

    /// Audio still being written or processed: nothing may act on it yet
    /// (reprocess, split/trim, delete) — the pipeline owns it.
    var isInProgress: Bool {
        [.recording, .transcribing, .diarizing].contains(self)
    }
}

// MARK: - Meeting Source

enum MeetingSource: String, Codable, DatabaseValueConvertible {
    case recording
    case `import`
}

// MARK: - Foreign voices on the mic track

/// What was decided about foreign voices on this meeting's mic track
/// (`foreign-voices-on-mic`, решение 6). A decision — taken by the user or by
/// the silently applied default — is older than the setting: changing the
/// setting later never replays it.
///
/// `undecided` exists because the two silent outcomes leave different traces:
/// hidden speech is visible as exclusion marks, kept speech leaves nothing at
/// all, and a meeting nobody has ruled on would be indistinguishable from one
/// that was quietly left alone. It has to be written down.
enum ForeignVoiceDecision: String, Codable, DatabaseValueConvertible {
    /// Nobody has ruled on this meeting yet — offer the question.
    case undecided
    /// Foreign voices stay visible. This is also what «запись с несколькими
    /// людьми на микрофоне» pins onto a meeting up front.
    case kept
    /// Foreign voices are hidden behind exclusion marks; restoring is one click.
    case hidden
}

// MARK: - Meeting

struct Meeting: Identifiable, Codable, FetchableRecord, PersistableRecord {
    var id: String
    var title: String
    var startTime: Date
    var endTime: Date?
    var durationSeconds: Double?
    var language: String
    var calendarEventId: String?
    var seriesId: String?
    var source: MeetingSource
    var sourceFilePath: String?
    var micAudioPath: String?
    var systemAudioPath: String?
    var status: MeetingStatus
    var description: String?
    /// Which diarizer produced this meeting's segment embeddings ('online' /
    /// 'offline'; NULL for legacy) — the embedding-space marker the dual
    /// canonical pools key on. Written by `setDiarizer` on every
    /// (re)process; carried across split/undo so offline vectors never leak
    /// into the v1 pool (speaker-row-per-mint).
    var diarizer: String?
    /// Whether foreign voices on this meeting's mic track are shown or hidden,
    /// and whether that has been settled at all. A display property, not a
    /// processing one: flipping it takes effect immediately, no reprocess.
    var foreignVoiceDecision: ForeignVoiceDecision
    /// Why the status is `needsAttention` or `error` — see `MeetingStatusReason`.
    /// Written together with the status by `updateStatus`; NULL when unknown.
    var statusReason: String?
    var createdAt: Date

    static let databaseTableName = "meetings"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let title = Column(CodingKeys.title)
        static let startTime = Column(CodingKeys.startTime)
        static let endTime = Column(CodingKeys.endTime)
        static let durationSeconds = Column(CodingKeys.durationSeconds)
        static let language = Column(CodingKeys.language)
        static let status = Column(CodingKeys.status)
        static let source = Column(CodingKeys.source)
        static let description = Column(CodingKeys.description)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        durationSeconds: Double? = nil,
        language: String = "ru",
        calendarEventId: String? = nil,
        seriesId: String? = nil,
        source: MeetingSource = .recording,
        sourceFilePath: String? = nil,
        micAudioPath: String? = nil,
        systemAudioPath: String? = nil,
        status: MeetingStatus = .recording,
        description: String? = nil,
        diarizer: String? = nil,
        foreignVoiceDecision: ForeignVoiceDecision = .undecided,
        statusReason: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.language = language
        self.calendarEventId = calendarEventId
        self.seriesId = seriesId
        self.source = source
        self.sourceFilePath = sourceFilePath
        self.micAudioPath = micAudioPath
        self.systemAudioPath = systemAudioPath
        self.status = status
        self.description = description
        self.diarizer = diarizer
        self.foreignVoiceDecision = foreignVoiceDecision
        self.statusReason = statusReason
        self.createdAt = createdAt
    }
}

extension Meeting {
    /// The imported file, for as long as the import has not been processed to
    /// the end (the pipeline removes it then). An import that failed or was
    /// interrupted starts again from here, never from the `mic.wav` its
    /// extraction left: that one may be cut short, and a run over it ended by
    /// deleting this file — the only full copy.
    var importedOriginal: URL? {
        guard source == .import, let path = sourceFilePath, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Meetings a previous run left recording or processing — what crash
    /// recovery picks up. A row created since this process started, or one it
    /// is working on (`live`), is its own work: a command that starts an
    /// import or a recording during a cold start lands before the first load,
    /// and "recovering" it ran a second pipeline over the first.
    static func orphans(among meetings: [Meeting], launchedAt: Date, live: Set<String>) -> [Meeting] {
        meetings.filter { $0.status.isInProgress && $0.createdAt < launchedAt && !live.contains($0.id) }
    }
}

// MARK: - Segment Source

enum SegmentSource: String, Codable, DatabaseValueConvertible {
    case mic
    case system
    case merged
    case `import`
}

// MARK: - TranscriptSegment

struct TranscriptSegment: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var meetingId: String
    var speakerId: String?
    var speakerLabel: String?
    var source: SegmentSource
    var startTime: Double
    var endTime: Double
    var text: String
    var originalText: String?
    var isEdited: Bool
    var confidence: Double?
    var embedding: Data?
    /// Derived cache of the exclusion projection (change
    /// `transcript-exclusion-marks`). Truth lives in `meeting_marks`; this
    /// flag is recomputed by `MarkRepository.reproject` and keeps the hot
    /// read path (UI, search, export, MCP, embedding recalc) join-free.
    var isExcluded: Bool

    static let databaseTableName = "transcript_segments"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let meetingId = Column(CodingKeys.meetingId)
        static let speakerId = Column(CodingKeys.speakerId)
        static let speakerLabel = Column(CodingKeys.speakerLabel)
        static let source = Column(CodingKeys.source)
        static let startTime = Column(CodingKeys.startTime)
        static let endTime = Column(CodingKeys.endTime)
        static let text = Column(CodingKeys.text)
        static let isExcluded = Column(CodingKeys.isExcluded)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    init(
        id: Int64? = nil,
        meetingId: String,
        speakerId: String? = nil,
        speakerLabel: String? = nil,
        source: SegmentSource,
        startTime: Double,
        endTime: Double,
        text: String,
        originalText: String? = nil,
        isEdited: Bool = false,
        confidence: Double? = nil,
        embedding: Data? = nil,
        isExcluded: Bool = false
    ) {
        self.id = id
        self.meetingId = meetingId
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.originalText = originalText
        self.isEdited = isEdited
        self.confidence = confidence
        self.embedding = embedding
        self.isExcluded = isExcluded
    }
}

// MARK: - Time Formatting

extension TranscriptSegment {
    var formattedTimeRange: String {
        "\(Self.formatTime(startTime)) → \(Self.formatTime(endTime))"
    }

    static func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    /// The window's timecode, `0:14` or `1:02:03`; export and the clipboard keep `formatTime`.
    static func windowTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func windowTimeRange(_ start: Double, _ end: Double) -> String {
        "\(windowTime(start))—\(windowTime(end))"
    }
}
