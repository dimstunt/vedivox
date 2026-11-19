import Foundation

/// The names the app had before it became Vedivox.
///
/// Nothing new is written under them. They are here for reading what the old
/// name left behind: a library in the old folder, settings in the old domain,
/// backups made by an older build, links in meeting notes and in people's
/// task lists.
enum LegacyNames {
    static let appName = "Vox"
    static let bundleIdentifier = "com.dimstunt.Vox"

    /// The data directory under Application Support.
    static let dataDirectoryName = "Vox"

    /// `vox://meeting/<id>?t=<seconds>`, as copied into notes and tasks.
    static let urlScheme = "vox"

    /// Automatic database backups: `Vox-<stamp>.sqlite`.
    static let backupPrefix = "Vox-"

    /// Stored palette choices and what the same palettes are called now.
    static let paletteRawValues = ["vox": "mono", "dimstunt": "ink"]

    /// Files in the data directory that carried the old name, with their names
    /// of today. A database's write-ahead log and its index come before the
    /// database: SQLite finds them by the database's name, so the database must
    /// never be the one that has moved while they have not.
    static let renamedFiles: [(old: String, new: String)] = [
        ("Vox.sqlite-wal", "Vedivox.sqlite-wal"),
        ("Vox.sqlite-shm", "Vedivox.sqlite-shm"),
        ("Vox.sqlite", "Vedivox.sqlite"),
        ("logs/vox.log", "logs/vedivox.log"),
    ] + (1 ... 4).map { ("logs/vox.\($0).log", "logs/vedivox.\($0).log") }

    /// The one file of `renamedFiles` the app cannot start without.
    static let databaseFileName = "Vox.sqlite"
}
