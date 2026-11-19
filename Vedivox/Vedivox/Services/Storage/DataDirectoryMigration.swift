import Darwin
import Foundation
import GRDB

/// Brings a library kept under the app's old name to where Vedivox looks for it.
///
/// Three things carried the old name: the data directory, a few files inside
/// it, and the absolute paths the database stores. Each has a step here, and
/// each step either completes or leaves what it found. Nothing is copied,
/// merged or deleted: the library moves whole by one `rename`, which within a
/// volume is atomic and takes the same instant for 20 MB and for 20 GB.
///
/// The first two steps run before anything else in the process, and they do
/// not log. The log lives in the data directory, so its first line would
/// create the very directory the move needs to find absent. What happened is
/// returned, and the caller logs it once the directory is in place.
enum DataDirectoryMigration {
    enum Outcome: Equatable {
        /// Nothing under the old name.
        case nothingToMove
        /// Done: what was under the old name is under the new one.
        case moved
        /// A library under each name. The new one is used, nothing is merged.
        case bothExist
        /// Another instance holds the directory — for the move, the app under
        /// its old name, still running.
        case inUse(DataDirectoryHolder?)
        /// Refused, with the reason. Everything is where it was.
        case failed(String)
    }

    /// `rename(2)`, replaceable so a test can make it fail.
    typealias Rename = (_ from: String, _ to: String) -> Int32

    /// Where the app kept its data under the old name.
    static var legacyProduction: URL {
        DataDirectory.production.deletingLastPathComponent()
            .appendingPathComponent(LegacyNames.dataDirectoryName, isDirectory: true)
    }

    // MARK: - The Directory

    /// Moves the library at `legacy` to `current`, when there is one and the
    /// new place is free.
    static func move(
        from legacy: URL,
        to current: URL,
        rename: Rename = { Darwin.rename($0, $1) }
    ) -> Outcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .nothingToMove }

        // An empty directory under the new name is not a second library, and
        // `rename` replaces it. Anything inside makes it one.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: current.path), !entries.isEmpty {
            return .bothExist
        }

        let outcome = holdingLock(in: legacy) {
            guard rename(legacy.path, current.path) == 0 else {
                let reason = errno
                // Something appeared there between the look above and now.
                if reason == ENOTEMPTY || reason == EEXIST { return .bothExist }
                return .failed("\(legacy.path) → \(current.path): \(String(cString: strerror(reason)))")
            }
            return .moved
        }
        // Gone since the look above: another copy of the app, started at the
        // same moment, has just moved it. That is not a failure to report.
        if case .failed = outcome, !FileManager.default.fileExists(atPath: legacy.path) {
            return .nothingToMove
        }
        return outcome
    }

    // MARK: - The Files Inside

    /// Gives the files that carried the old name the names they have today:
    /// the database with its write-ahead log, and the log files.
    ///
    /// Runs on every launch and normally finds nothing to do. A file is renamed
    /// only when its new name is free, so a run cut short is finished by the
    /// next one. Where a database exists under each name, neither is touched,
    /// nor is either's write-ahead log: the log of one must never end up
    /// beside the other.
    ///
    /// `.failed` means the database could not get its name. The app must stop
    /// then: going on would start an empty database next to the real one.
    static func renameFiles(in root: URL, rename: Rename = { Darwin.rename($0, $1) }) -> Outcome {
        func path(_ name: String) -> String { root.appendingPathComponent(name).path }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

        let twoDatabases = LegacyNames.renamedFiles.contains {
            $0.old == LegacyNames.databaseFileName && exists($0.old) && exists($0.new)
        }
        let pending = LegacyNames.renamedFiles.filter { file in
            if twoDatabases, file.old.hasPrefix(LegacyNames.databaseFileName) { return false }
            return exists(file.old) && !exists(file.new)
        }
        guard !pending.isEmpty else { return .nothingToMove }

        return holdingLock(in: root) {
            var failure: String?
            for file in pending where rename(path(file.old), path(file.new)) != 0 {
                let reason = String(cString: strerror(errno))
                if file.old == LegacyNames.databaseFileName {
                    failure = "\(path(file.old)) → \(path(file.new)): \(reason)"
                }
            }
            return failure.map(Outcome.failed) ?? .moved
        }
    }

    // MARK: - The Paths In The Database

    /// The columns of `meetings` that hold absolute paths.
    private static let pathColumns = ["micAudioPath", "systemAudioPath", "sourceFilePath"]

    /// Points the paths the database stores at the library's new place: a path
    /// under `oldRoot` becomes the same path under `newRoot`. A path anywhere
    /// else — an imported file left in Downloads — stays as it is.
    static func rewriteStoredPaths(_ db: Database, from oldRoot: String, to newRoot: String) throws {
        let old = oldRoot.hasSuffix("/") ? oldRoot : oldRoot + "/"
        let new = newRoot.hasSuffix("/") ? newRoot : newRoot + "/"
        for column in pathColumns {
            try db.execute(sql: """
                UPDATE meetings SET \(column) = ? || substr(\(column), length(?) + 1)
                WHERE substr(\(column), 1, length(?)) = ?
                """, arguments: [new, old, old, old])
        }
    }

    // MARK: - The Lock

    /// Runs `body` holding the directory's instance lock, taken without a log
    /// line. A running instance holds the same lock, and one that starts in
    /// the middle finds it taken and steps back.
    private static func holdingLock(in directory: URL, _ body: () -> Outcome) -> Outcome {
        let path = DataDirectoryLock.lockFileURL(in: directory).path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            return .failed("\(path): \(String(cString: strerror(errno)))")
        }
        // Closing the descriptor releases the lock, wherever the file is by then.
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            return reason == EWOULDBLOCK
                ? .inUse(DataDirectoryLock.readHolder(in: directory))
                : .failed("\(path): \(String(cString: strerror(reason)))")
        }
        return body()
    }
}

/// Carries the settings kept under the app's old identifier into the new one.
///
/// Once: after the first look the new domain is on its own, and the old one is
/// read, never written.
enum LegacySettings {
    /// Set in the new domain once the old one has been looked at.
    static let checkedKey = "legacySettingsChecked"

    /// Left behind on purpose. Onboarding is the walk through the permissions,
    /// and macOS grants those to an identifier: under the new one the app has
    /// none of them, so the walk is due again — and the old app's proof of
    /// system audio is not the new one's.
    static let leftBehind: Set<String> = ["onboardingCompleted", PermissionFacts.systemAudioHeardKey]

    /// What the new domain gains: every old setting it does not have itself.
    static func carriedOver(from legacy: [String: Any], into current: [String: Any]) -> [String: Any] {
        legacy.filter { current[$0.key] == nil && !leftBehind.contains($0.key) }
    }

    /// Copies the old domain's settings into `defaults`, the first time only.
    /// Returns how many came over, or nil when the look has been taken before.
    @discardableResult
    static func adopt(
        into defaults: UserDefaults = .standard,
        domain: String? = Bundle.main.bundleIdentifier,
        legacy: [String: Any]? = UserDefaults.standard.persistentDomain(forName: LegacyNames.bundleIdentifier)
    ) -> Int? {
        guard !defaults.bool(forKey: checkedKey) else { return nil }
        let current = domain.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let carried = carriedOver(from: legacy ?? [:], into: current)
        for (key, value) in carried { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: checkedKey)
        return carried.count
    }
}
