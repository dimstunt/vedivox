import Foundation

/// Why a meeting is `needsAttention` or `error`. The raw values are
/// what the pipeline logs in «needs attention: …» and what `meetings.statusReason`
/// stores, comma-separated; `help` turns them into the badge's tooltip.
enum MeetingStatusReason: String, CaseIterable {
    case micLost = "mic"
    case systemLost = "system"
    case systemDiarization = "system diarization"
    case diarization
    case micCompression = "mic compression"
    case systemCompression = "system compression"
    case micEmpty = "mic empty"
    case recoveryInterrupted = "recovery interrupted"
    case noAudio = "no audio"
    /// The same string as `SilentCallTrack.attention` (a test keeps them equal).
    case systemSilentDuringCall = "system silent during call"
    /// The same string as `TapChopDetector.attention` (a test keeps them equal).
    case systemChopped = "system chopped"

    private static let separator = ", "

    /// The column value for a list of reasons; nil when there are none.
    static func stored(_ reasons: [String]) -> String? {
        reasons.isEmpty ? nil : reasons.joined(separator: separator)
    }

    var explanation: String {
        switch self {
        case .micLost:
            "Your microphone picked up sound, but no speech was recognized in it. "
                + "Reprocess the meeting; if the text is still missing, listen to the recording."
        case .systemLost:
            "The call audio had sound, but no speech was recognized in it. "
                + "Reprocess the meeting; if the text is still missing, listen to the recording."
        case .systemDiarization:
            "The voices on the call could not be told apart, so they are not split into speakers. "
                + "Reprocess the meeting to try again."
        case .diarization:
            "The voices in this recording could not be told apart, so they are not split into speakers. "
                + "Reprocess the meeting to try again."
        case .micCompression:
            "The microphone track could not be compressed. Nothing is lost — the original file is kept, "
                + "it just takes more disk space. Reprocess the meeting to try again."
        case .systemCompression:
            "The call audio could not be compressed. Nothing is lost — the original file is kept, "
                + "it just takes more disk space. Reprocess the meeting to try again."
        case .micEmpty:
            "Nothing was recorded from the microphone: the file is empty. "
                + "Check the microphone in Settings → Recording before the next call."
        case .recoveryInterrupted:
            "Vedivox quit while finishing this meeting after an earlier crash, so it stopped retrying. "
                + "Reprocess the meeting to try again."
        case .noAudio:
            "The audio file of this recording was not found, so there is nothing to transcribe."
        case .systemSilentDuringCall:
            "The call was playing sound, but nothing reached the recording: the other participants are missing. "
                + "Check System audio in Settings → Privacy & Permissions before the next call."
        case .systemChopped:
            "For a while the call audio came through chopped into short pieces, so part of what the other "
                + "participants said is missing. If it happens again during a call, switch the speaker in the call app "
                + "to another device and back."
        }
    }

    static let notSaved = "The reason was not saved: this meeting was processed before Vedivox kept it. "
        + "Reprocess the meeting to see it."
    static let unknownFailure = "Processing failed. Reprocess the meeting to try again; the details are in the log."
    static let unknownAttention = "Something in this meeting needs a look; the details are in the log."

    /// The tooltip of a meeting's status badge; nil for statuses without one.
    static func help(status: MeetingStatus, stored: String?) -> String? {
        guard status == .needsAttention || status == .error else { return nil }
        guard let stored, !stored.isEmpty else {
            return status == .needsAttention ? notSaved : unknownFailure
        }
        var lines: [String] = []
        for code in stored.components(separatedBy: separator) {
            let line = Self(rawValue: code)?.explanation ?? unknownAttention
            if !lines.contains(line) { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }
}
