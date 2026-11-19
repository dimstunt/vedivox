import Foundation

/// Single source of truth for the directory that holds Vedivox's data — database,
/// audio, dictations, logs and vocabulary.
///
/// The path used to be spelled out independently in six places. That made
/// pointing a build at a copy of the data impossible in practice: any attempt
/// was guaranteed to miss one of the six and write into the live directory
/// anyway. Everything that needs a path asks here now.
///
/// Deliberately free of dependencies — `FileLogger` resolves its directory
/// through this type, so logging from here would be a cycle at initialization.
enum DataDirectory {
    /// Environment variable naming an alternative data directory.
    static let environmentKey = "VEDIVOX_DATA_DIR"

    /// Command-line form of the same setting: `-VedivoxDataDirectory <path>`.
    static let argumentKey = "-VedivoxDataDirectory"

    /// Directory under Application Support used when nothing is configured.
    static let productionDirectoryName = "Vedivox"

    /// Directory used by a test process that has not been pointed anywhere.
    ///
    /// A sibling of the production directory, never inside it. `DatabaseManager`
    /// already keeps tests off the live database by file name; this keeps the
    /// other four kinds of data — log, audio, dictations, vocabulary — off the
    /// live directory as well. Without it every `make test` wrote its temporary
    /// lock and socket paths into the user's real log.
    static let testDirectoryName = "Vedivox-tests"

    /// The resolved data directory for this process.
    ///
    /// Resolved once: the answer must not change between the database opening
    /// and the log rotating, or the two halves of one run end up in different
    /// directories.
    static let root: URL = resolve(
        environment: ProcessInfo.processInfo.environment,
        arguments: ProcessInfo.processInfo.arguments
    )

    // MARK: - Known Subdirectories

    /// Per-meeting recordings: `<root>/audio/<meetingId>/`.
    static var audio: URL { subdirectory("audio") }

    /// Dictation recordings, kept apart from meetings so retention can sweep
    /// them without ever looking at meeting audio.
    static var dictations: URL { subdirectory("dictations") }

    /// Rotating application log.
    static var logs: URL { subdirectory("logs") }

    /// User vocabulary for transcription term normalization.
    static var vocabulary: URL { subdirectory("vocabulary") }

    static func subdirectory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Resolution

    /// The production directory, used when no data directory is configured.
    static var production: URL {
        applicationSupport.appendingPathComponent(productionDirectoryName, isDirectory: true)
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    /// Pure resolution, exposed so tests can drive it without touching the
    /// running process.
    ///
    /// The command-line argument wins over the environment variable: it is set
    /// per launch, so it is the more specific statement of intent when a scheme
    /// happens to carry both.
    static func resolve(environment: [String: String], arguments: [String]) -> URL {
        if let configured = configuredPath(environment: environment, arguments: arguments) {
            return URL(
                fileURLWithPath: (configured as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }

        // An explicit directory still wins: a test that asks for a particular
        // one gets it. This only covers the test that asked for nothing, which
        // would otherwise land in the user's live directory by default.
        if isTestProcess(environment: environment) {
            return applicationSupport.appendingPathComponent(testDirectoryName, isDirectory: true)
        }

        return production
    }

    /// Whether this process is an XCTest run.
    ///
    /// Both variables are checked because the host sets them in different
    /// combinations; `DatabaseManager` looks at the same pair.
    static func isTestProcess(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    private static func configuredPath(environment: [String: String], arguments: [String]) -> String? {
        if let flag = arguments.firstIndex(of: argumentKey) {
            let valueIndex = arguments.index(after: flag)
            if valueIndex < arguments.endIndex {
                let value = arguments[valueIndex].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }

        if let value = environment[environmentKey]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return value
        }

        return nil
    }
}
