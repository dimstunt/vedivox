import Foundation

/// Label → speaker record bindings of one meeting (stage2-out-of-pool).
///
/// A segment label is how speech gets bound to a record downstream
/// (`renameSpeakerInMeeting` rewrites every segment of the meeting with that
/// label), so one label must name exactly one record. Keyed by display name,
/// two records called the same — two confirmed `speaker_1`, or two people the
/// user named «Катя» — collapsed into whichever was bound last.
struct SpeakerLabelBook {
    private(set) var bindings: [String: String]
    /// Labels taken by speech not bound yet (the other track's fresh `speaker_N`).
    private let reserved: Set<String>

    init(bindings: [String: String] = [:], reserved: Set<String> = []) {
        self.bindings = bindings
        self.reserved = reserved
    }

    /// The label `speakerId` goes by in this meeting, binding it on first use.
    /// A name already bound to another record gets a distinct label: an auto
    /// label moves to the next free `speaker_N`, a name the user gave takes a
    /// ` (2)`, ` (3)`, … suffix.
    mutating func label(for displayName: String, speakerId: String) -> String {
        // A record keeps the label it already has here (min: deterministic if it has several).
        if let existing = bindings.filter({ $0.value == speakerId }).keys.min() {
            return existing
        }
        var label = displayName
        if isTaken(label) {
            if Speaker.isAutoLabel(displayName) {
                label = "speaker_\(highestAutoNumber() + 1)"
            } else {
                var n = 2
                while isTaken("\(displayName) (\(n))") { n += 1 }
                label = "\(displayName) (\(n))"
            }
        }
        bindings[label] = speakerId
        return label
    }

    /// Highest `speaker_N` taken by any bound or reserved label — minting continues after it.
    func highestAutoNumber() -> Int {
        (Array(bindings.keys) + reserved).compactMap { name -> Int? in
            guard Speaker.isAutoLabel(name) else { return nil }
            return Int(name.dropFirst(8))
        }.max() ?? 0
    }

    private func isTaken(_ label: String) -> Bool {
        bindings[label] != nil || reserved.contains(label)
    }
}
