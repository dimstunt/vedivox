import Foundation
import GRDB

/// One dictation: what was said, where it went, and whether it arrived
///
/// Deliberately not a `Meeting`. A dictation has no speakers, no diarization and
/// no series, and putting it in the meetings table would drop it into meeting
/// lists and the diarization pipeline — the existing code says as much in
/// several places.
///
/// A row is written whether or not insertion succeeded. Until now the text
/// existed in exactly one place: the field it landed in. If it landed in the
/// wrong window there was nothing to recover from.
struct Dictation: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    var id: String
    var createdAt: Date
    /// Final text, from the offline pass — not the live draft.
    var text: String
    var durationSeconds: Double
    /// Which app the text went to, by name. Nil when there was no frontmost app
    /// or insertion never happened.
    ///
    /// Recorded because the target is chosen at paste time: text quietly landing
    /// in the wrong window is otherwise invisible, and the HUD is gone by then.
    var targetApp: String?
    /// False when the text only reached the clipboard.
    var inserted: Bool
    /// File name inside the dictation audio directory, or nil once retention has
    /// removed the audio. The text always outlives the audio.
    var audioFileName: String?
    /// Saved by a quit or a crash mid-dictation: the audio is kept,
    /// recognition is still owed, and nothing is ever inserted for it.
    var awaitingTranscription = false

    static let databaseTableName = "dictations"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let createdAt = Column(CodingKeys.createdAt)
        static let text = Column(CodingKeys.text)
        static let durationSeconds = Column(CodingKeys.durationSeconds)
        static let targetApp = Column(CodingKeys.targetApp)
        static let inserted = Column(CodingKeys.inserted)
        static let audioFileName = Column(CodingKeys.audioFileName)
        static let awaitingTranscription = Column(CodingKeys.awaitingTranscription)
    }

    /// Whether the audio is still around — the deciding factor for offering
    /// re-transcription.
    var hasAudio: Bool { audioFileName != nil }
}
