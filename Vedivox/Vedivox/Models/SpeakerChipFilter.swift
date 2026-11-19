import Foundation

/// Speaker chips over a set of meetings (Series page): who spoke in how many of
/// them, and which meetings hold every chosen chip.
struct SpeakerChipFilter {
    /// A speaker with at least one kept line in a meeting.
    struct Link: Hashable {
        let meetingId: String
        let speakerId: String
    }

    enum Key: Hashable {
        case speaker(String)
        /// Every `speaker_N` together: the same label in two meetings is two different people.
        case unnamed
    }

    struct Chip: Identifiable {
        let key: Key
        /// nil for the unnamed chip.
        let speaker: Speaker?
        /// Speakers behind the chip: 1 for a named one.
        let speakerCount: Int
        let meetingCount: Int
        var id: Key { key }
        var label: String { speaker?.displayName ?? "\(speakerCount) unnamed" }
    }

    /// Named speakers, most meetings first, then by name; the unnamed chip last.
    let chips: [Chip]
    private let meetingsByKey: [Key: Set<String>]
    /// Everyone who spoke, the unnamed counted one by one.
    var speakerCount: Int { chips.reduce(0) { $0 + $1.speakerCount } }

    init(speakers: [Speaker] = [], links: [Link] = []) {
        let unnamedIds = Set(speakers.filter { Speaker.isAutoLabel($0.displayName) }.map(\.id))
        var byKey: [Key: Set<String>] = [:]
        for link in links {
            let key: Key = unnamedIds.contains(link.speakerId) ? .unnamed : .speaker(link.speakerId)
            byKey[key, default: []].insert(link.meetingId)
        }
        meetingsByKey = byKey
        var named: [Chip] = []
        for speaker in speakers where !unnamedIds.contains(speaker.id) {
            guard let ids = byKey[.speaker(speaker.id)] else { continue }
            named.append(Chip(key: .speaker(speaker.id), speaker: speaker, speakerCount: 1, meetingCount: ids.count))
        }
        named.sort { (a: Chip, b: Chip) -> Bool in
            if a.meetingCount != b.meetingCount { return a.meetingCount > b.meetingCount }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
        let unnamedCount = Set(links.map(\.speakerId)).intersection(unnamedIds).count
        let unnamed = byKey[.unnamed].map {
            Chip(key: .unnamed, speaker: nil, speakerCount: unnamedCount, meetingCount: $0.count)
        }
        chips = named + (unnamed.map { [$0] } ?? [])
    }

    /// The meetings that hold every selected chip, in their order; all of them when nothing is selected.
    func filter(_ meetings: [Meeting], selection: Set<Key>) -> [Meeting] {
        let required = selection.map { meetingsByKey[$0] ?? [] }
        return meetings.filter { meeting in required.allSatisfy { $0.contains(meeting.id) } }
    }
}
