import Foundation

/// A command addressed to the instance that owns a data directory.
///
/// Deliberately a name plus flat string parameters rather than an enum with
/// associated values. The senders live in a different package (`VedivoxMCP`, and
/// later the command-line tool), so the wire format has to be reproducible on
/// the other side without sharing Swift types — and a format that is obvious to
/// re-implement is one that cannot quietly drift apart from its counterpart.
struct AppCommandRequest: Codable, Sendable, Equatable {
    var command: String
    var params: [String: String]

    init(command: String, params: [String: String] = [:]) {
        self.command = command
        self.params = params
    }
}

/// The outcome of executing a command.
///
/// `ok` describes the requested action, not its delivery: a command that was
/// received and then failed reports `ok == false`. Reporting delivery as
/// success is the specific dishonesty this change exists to remove.
struct AppCommandResponse: Codable, Sendable, Equatable {
    var ok: Bool
    var message: String
    /// Machine-readable failure reason. Absent on success.
    var reason: String?
    /// Flat result fields for machine output (e.g. `meeting_id`). Optional on
    /// the wire: senders that do not know it ignore it.
    var data: [String: String]? = nil

    static func success(_ message: String, data: [String: String]? = nil) -> AppCommandResponse {
        AppCommandResponse(ok: true, message: message, reason: nil, data: data)
    }

    static func failure(_ message: String, reason: Reason) -> AppCommandResponse {
        AppCommandResponse(ok: false, message: message, reason: reason.rawValue)
    }

    /// Why a command could not be carried out.
    ///
    /// Named reasons exist so a caller can act on the difference — "no such
    /// meeting" and "the app is not answering" call for different responses,
    /// and a caller that can only read prose has to guess.
    enum Reason: String, Sendable {
        case unknownCommand = "unknown_command"
        case invalidParameters = "invalid_parameters"
        case notFound = "not_found"
        case missingAudio = "missing_audio"
        case notReady = "not_ready"
        case failed = "failed"
        case unreachable = "unreachable"
        case timedOut = "timed_out"
    }
}

/// Command names on the wire.
///
/// One list, referenced by both the app and every sender, so a typo is a
/// compile error on this side and a single lookup on the other.
enum AppCommandName {
    static let openMeeting = "open_meeting"
    static let reprocessMeeting = "reprocess_meeting"
    static let importFile = "import_file"
    /// Transcribe + diarize a file and return the segments; nothing is stored.
    static let transcribeFile = "transcribe_file"
    static let exportMeeting = "export_meeting"
    static let ping = "ping"

    // Data changes. They travel the same socket as the actions above because
    // the app is the only writer: an external process that edits the database
    // directly bypasses the app's state, which is why the UI had to be nudged
    // by a separate notification to notice its own data changing.
    static let updateSpeaker = "update_speaker"
    static let mergeSpeakers = "merge_speakers"
    static let detachMeetings = "detach_meetings"
    /// Lines go anonymous per meeting, verdicts and the record are deleted.
    static let deleteSpeaker = "delete_speaker"
    static let updateSegment = "update_segment"
    static let updateMeeting = "update_meeting"
    /// Same path as the UI delete: audio to the Trash, rows out of the DB.
    static let deleteMeetings = "delete_meetings"
    // The window's Split, Trim, Merge and their Undo (cli-meeting-edit).
    static let splitMeeting = "split_meeting"
    static let trimMeeting = "trim_meeting"
    static let mergeMeetings = "merge_meetings"
    static let undoMeetingEdit = "undo_meeting_edit"
    static let createSeries = "create_series"
    static let updateSeries = "update_series"
    static let deleteSeries = "delete_series"
    /// Fold a duplicate series into another (`vedivox series merge`).
    static let mergeSeries = "merge_series"
    /// Every series' auto-rule over the series-less meetings (`vedivox series apply-rules`).
    static let applySeriesRules = "apply_series_rules"
    static let markExcluded = "mark_excluded"
    static let unmark = "unmark"

    // Recording control (`vedivox record start|stop`).
    static let startRecording = "start_recording"
    static let stopRecording = "stop_recording"
    /// Live text of the recording in progress (`vedivox live`); nothing is stored.
    static let liveTranscript = "live_transcript"

    /// One-shot re-encode of the archive to the storage preset (`vedivox audio compact`).
    static let compactAudio = "compact_audio"

    /// What the call-mute readers see now, with the Teams AX tree (`vedivox mute-debug`).
    static let diagnoseMute = "diagnose_mute"

    // Listen queue (listen-queue § 8).
    static let listListenQueue = "list_listen_queue"
    static let assignVoice = "assign_voice"
    static let skipVoice = "skip_voice"
    static let assignRange = "assign_range"
    static let pinSpeakers = "pin_speakers"
}
