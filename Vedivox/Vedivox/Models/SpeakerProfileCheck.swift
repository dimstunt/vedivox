import Foundation

/// What stands in the way of saving a speaker profile. A blank
/// name, or a blank nickname that still wins `displayName`, labelled every
/// line with nothing; a `speaker_N` name hid the speaker from the list; a name
/// another record already has made `findOrCreateSpeaker` pick either of them.
enum SpeakerProfileCheck: Equatable {
    case ok
    case empty
    case autoLabel
    /// Another record answers to one of the names: offer a merge instead.
    case taken(speakerId: String, name: String)

    /// Fields are compared trimmed; names match case-insensitively.
    static func check(
        nameEn: String, nickname: String, nameRu: String, speakerId: String, others: [Speaker]
    ) -> SpeakerProfileCheck {
        let mine = [nameEn, nickname, nameRu].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !mine[0].isEmpty else { return .empty }
        let named = mine.filter { !$0.isEmpty }
        if named.contains(where: Speaker.isAutoLabel) { return .autoLabel }
        for other in others where other.id != speakerId {
            let theirs = [other.nameEn, other.nickname ?? "", other.nameRu ?? ""]
            if named.contains(where: { name in theirs.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }) {
                return .taken(speakerId: other.id, name: other.displayName)
            }
        }
        return .ok
    }
}
