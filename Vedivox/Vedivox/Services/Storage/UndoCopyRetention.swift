import Foundation

/// Undo copies of trim, split and merge expire after `days` (compact-meeting-storage § 4).
///
/// They were kept forever and had grown to 2.4 GB, an eighth of all audio. Age comes from
/// `split_info.json` / `merge_info.json`, or — for a trim, and for a copy whose info file
/// is gone — from the newest current track: every trim and split rewrites it, so it is
/// never older than the operation. The copies' own mtimes are useless: `moveItem` and
/// `copyItem` keep the recording's date, so a fresh trim of an old meeting would look
/// expired.
///
/// The info file goes first, then the audio: a crash in between leaves audio with no
/// undo, which the next launch collects, never an undo with no audio behind it.
enum UndoCopyRetention {
    static let days = 7

    private static let kinds: [(info: String?, copies: [String])] = [
        ("split_info.json", MeetingRepository.trackNames.map { "\($0)_presplit.m4a" }),
        ("merge_info.json", MeetingRepository.trackNames.map { "\($0)_premerge.m4a" }),
        // `canUndoTrim` looks at mic_pretrim, so it goes first; trim_info.json goes with the copies.
        (nil, MeetingRepository.trackNames.map { "\($0)_pretrim.m4a" } + [MeetingRepository.trimInfoFile]),
    ]

    /// Returns how many files were removed.
    @discardableResult
    static func pruneExpired(audioRoot: URL = DataDirectory.audio, now: Date = Date()) -> Int {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        guard let meetingDirs = try? fm.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil) else { return 0 }

        var removed = 0
        for dir in meetingDirs {
            let tracksDate = ["mic.m4a", "system.m4a"].compactMap { modificationDate(dir.appendingPathComponent($0)) }.max()
            for kind in kinds {
                let copies = kind.copies.map { dir.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
                guard !copies.isEmpty else { continue }
                let info = kind.info.map { dir.appendingPathComponent($0) }.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
                let age = info.flatMap(modificationDate) ?? tracksDate ?? copies.compactMap(modificationDate).max()
                guard let age, age < cutoff else { continue }

                for file in [info].compactMap({ $0 }) + copies {
                    do {
                        try fm.removeItem(at: file)
                        removed += 1
                    } catch {
                        Log.error("Undo copies: could not remove \(dir.lastPathComponent)/\(file.lastPathComponent): \(error.localizedDescription)")
                        break
                    }
                }
            }
        }
        Log.info(removed == 0
            ? "Undo copies: nothing older than \(days) days"
            : "Undo copies: removed \(removed) file(s) older than \(days) days")
        return removed
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
